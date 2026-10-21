import Foundation
import OSLog

public actor ElevenLabsRealtimeSession {
    private let logger = Logger(subsystem: "SpeechKit", category: "ElevenLabsRealtimeSession")
    private let configuration: ElevenLabsRealtimeSessionConfiguration
    private let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
    private let connection: RealtimeWebSocketConnection<ElevenLabsRealtimeEvent>

    private var hasSentFirstAudioChunk = false
    private var sentChunkCount = 0
    private var preferredLanguagesPreviousText: String?

    public init(
        configuration: ElevenLabsRealtimeSessionConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.connection = RealtimeWebSocketConnection(
            providerName: "ElevenLabs realtime",
            logger: logger,
            session: session ?? SpeechKitURLSessionFactory.realtimeSession(for: configuration.access),
            relay: configuration.access.relay,
            decodeEvent: { data in try ElevenLabsRealtimeAPI.decodeEvent(from: data) },
            isReadyEvent: { event in
                if case .sessionStarted = event {
                    return true
                }
                return false
            },
            alreadyConnectedError: ElevenLabsRealtimeSessionError.alreadyConnected,
            notConnectedError: ElevenLabsRealtimeSessionError.notConnected,
            invalidMessageError: { ElevenLabsRealtimeSessionError.invalidMessage($0) }
        )
    }

    public func connect(languageCode: String? = nil) async throws -> AsyncThrowingStream<ElevenLabsRealtimeEvent, Error> {
        let languageConditioning = configuration.languageConditioning(languageCode: languageCode)
        let request = try makeWebSocketRequest(languageCode: languageConditioning.languageCode)
        let stream = try await connection.connect(request: request)
        hasSentFirstAudioChunk = false
        sentChunkCount = 0
        preferredLanguagesPreviousText = languageConditioning.previousText
        return stream
    }

    public func waitUntilReady() async throws {
        try await connection.waitUntilReady()
    }

    public func sendAudioChunk(_ audioData: Data, previousText: String? = nil) async throws {
        guard !audioData.isEmpty else { return }

        try await waitUntilReady()

        let firstChunkPreviousText = previousText ?? preferredLanguagesPreviousText
        let payload = ElevenLabsRealtimeAPI.InputAudioChunkPayload(
            audioBase64: audioData.base64EncodedString(),
            commit: false,
            sampleRate: configuration.sampleRate,
            previousText: hasSentFirstAudioChunk ? nil : firstChunkPreviousText
        )

        let message = try encodeMessage(payload)
        logger.debug(
            "Outgoing ElevenLabs realtime chunk #\(self.sentChunkCount + 1, privacy: .public): bytes=\(audioData.count, privacy: .public) base64Chars=\(payload.audioBase64.count, privacy: .public) sampleRate=\(payload.sampleRate, privacy: .public) previousTextLen=\(payload.previousText?.count ?? 0, privacy: .public)"
        )
        try await connection.send(message)
        hasSentFirstAudioChunk = true
        sentChunkCount += 1
        if sentChunkCount == 1 {
            logger.info("Sent first ElevenLabs realtime audio chunk (\(audioData.count, privacy: .public) bytes)")
        }
    }

    public func requestCommit() async throws {
        try await waitUntilReady()
        let message = try makeCommitMessage()
        logger.debug("Outgoing ElevenLabs realtime commit payload: \(message, privacy: .public)")
        try await connection.send(message)
        hasSentFirstAudioChunk = true
        logger.info("Requested ElevenLabs realtime commit after \(self.sentChunkCount, privacy: .public) chunks")
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        await connection.disconnect(code: code)
        hasSentFirstAudioChunk = false
        sentChunkCount = 0
        preferredLanguagesPreviousText = nil
    }

    func makeWebSocketRequest(languageCode: String?) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ElevenLabsRealtimeSessionError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "model_id", value: configuration.modelID),
            URLQueryItem(name: "include_timestamps", value: configuration.includeTimestamps ? "true" : "false"),
            URLQueryItem(name: "audio_format", value: ElevenLabsRealtimeAPI.audioFormat),
            URLQueryItem(name: "commit_strategy", value: configuration.commitStrategy.rawValue),
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(configuration.vadSilenceThresholdSeconds)),
            URLQueryItem(name: "vad_threshold", value: String(configuration.vadThreshold)),
            URLQueryItem(name: "min_speech_duration_ms", value: String(configuration.minSpeechDurationMilliseconds)),
            URLQueryItem(name: "min_silence_duration_ms", value: String(configuration.minSilenceDurationMilliseconds)),
            URLQueryItem(name: "enable_logging", value: configuration.enableLogging ? "true" : "false"),
        ]

        if let languageCode, !languageCode.isEmpty {
            queryItems.append(URLQueryItem(name: "language_code", value: languageCode))
        }

        queryItems.append(contentsOf: configuration.keyterms.map {
            URLQueryItem(name: "keyterms", value: $0)
        })

        components.queryItems = queryItems

        guard let url = components.url else {
            throw ElevenLabsRealtimeSessionError.invalidURL
        }

        return try configuration.access.webSocketRequest(upstream: url)
    }

    func makeCommitMessage() throws -> String {
        // The production socket and ElevenLabs' current JavaScript SDK commit
        // with an empty audio chunk. The standalone `message_type: commit`
        // shown in one docs surface is rejected by the live VAD endpoint.
        try encodeMessage(
            ElevenLabsRealtimeAPI.InputAudioChunkPayload(
                audioBase64: "",
                commit: true,
                sampleRate: configuration.sampleRate,
                previousText: nil
            )
        )
    }

    private func encodeMessage<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ElevenLabsRealtimeSessionError.invalidMessage("Encoded payload was not valid UTF-8")
        }
        return string
    }
}

extension ElevenLabsRealtimeSession: RealtimeTranscriptionSession {
    public nonisolated var sampleRate: Int { configuration.sampleRate }

    public nonisolated var finalizationTimeout: Duration { .seconds(5) }

    public func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        let includesTimestamps = configuration.includeTimestamps
        return try await connect().realtimeTranscriptionEvents { event in
            Self.transcriptionEvents(from: event, includesTimestamps: includesTimestamps)
        }
    }

    public func sendAudioChunk(_ audioData: Data) async throws {
        try await sendAudioChunk(audioData, previousText: nil)
    }

    public func disconnect() async {
        await disconnect(code: .normalClosure)
    }

    nonisolated static func transcriptionEvents(
        from event: ElevenLabsRealtimeEvent,
        includesTimestamps: Bool
    ) -> [RealtimeTranscriptionEvent] {
        switch event {
        case .sessionStarted, .partialTranscript, .finalTranscript, .finalTranscriptWithTimestamps:
            []
        case .committedTranscript(let text) where includesTimestamps:
            [.committedTranscript(text)]
        case .committedTranscript(let text):
            [.committedTranscript(text), .finalizationCompleted]
        case .committedTranscriptWithTimestamps:
            [.finalizationCompleted]
        }
    }
}
