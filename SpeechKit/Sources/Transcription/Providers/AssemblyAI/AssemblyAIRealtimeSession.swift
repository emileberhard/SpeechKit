import Foundation
import OSLog

public actor AssemblyAIRealtimeSession {
    private let logger = Logger(subsystem: "SpeechKit", category: "AssemblyAIRealtimeSession")
    private let configuration: AssemblyAIRealtimeSessionConfiguration
    private let endpoint = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
    private let connection: RealtimeWebSocketConnection<AssemblyAIRealtimeEvent>

    private var sentChunkCount = 0
    private var hasCommitted = false

    public init(
        configuration: AssemblyAIRealtimeSessionConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.connection = RealtimeWebSocketConnection(
            providerName: "AssemblyAI realtime",
            logger: logger,
            session: session ?? SpeechKitURLSessionFactory.realtimeSession(for: configuration.access),
            relay: configuration.access.relay,
            decodeEvent: AssemblyAIRealtimeAPI.decodeEvent(from:),
            isReadyEvent: { event in
                if case .sessionStarted = event { return true }
                return false
            },
            isTerminalEvent: { event in
                if case .sessionTerminated = event { return true }
                return false
            },
            alreadyConnectedError: AssemblyAIRealtimeSessionError.alreadyConnected,
            notConnectedError: AssemblyAIRealtimeSessionError.notConnected,
            invalidMessageError: { AssemblyAIRealtimeSessionError.invalidMessage($0) },
            pingIntervalNanoseconds: nil
        )
    }

    public func connect(languageCode: String? = nil) async throws -> AsyncThrowingStream<AssemblyAIRealtimeEvent, Error> {
        let request = try makeWebSocketRequest(languageCode: languageCode)
        let stream = try await connection.connect(request: request)
        sentChunkCount = 0
        hasCommitted = false
        return stream
    }

    public func waitUntilReady() async throws {
        try await connection.waitUntilReady()
    }

    public func sendAudioChunk(_ audioData: Data) async throws {
        guard !audioData.isEmpty else { return }
        guard !hasCommitted else { throw AssemblyAIRealtimeSessionError.alreadyCommitted }

        try await waitUntilReady()
        try await connection.send(audioData)
        sentChunkCount += 1
        if sentChunkCount == 1 {
            logger.info("Sent first AssemblyAI realtime audio chunk (\(audioData.count, privacy: .public) bytes)")
        }
    }

    public func requestCommit() async throws {
        guard !hasCommitted else { throw AssemblyAIRealtimeSessionError.alreadyCommitted }
        try await waitUntilReady()
        guard !hasCommitted else { throw AssemblyAIRealtimeSessionError.alreadyCommitted }
        hasCommitted = true
        try await connection.send(try encodeMessage(AssemblyAIRealtimeAPI.forceEndpoint))
        try await connection.send(try encodeMessage(AssemblyAIRealtimeAPI.terminate))
        logger.info("Ended AssemblyAI realtime session after \(self.sentChunkCount, privacy: .public) chunks")
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        if code == .normalClosure, !hasCommitted, await connection.isReady {
            do {
                try await connection.send(try encodeMessage(AssemblyAIRealtimeAPI.terminate))
                let terminated = try await connection.waitUntilTerminal(timeout: .seconds(5))
                if !terminated {
                    logger.warning("Timed out waiting for AssemblyAI realtime termination")
                }
            } catch {
                logger.warning("AssemblyAI realtime termination failed: \(String(describing: error), privacy: .public)")
            }
        }

        await connection.disconnect(code: code)
        sentChunkCount = 0
        hasCommitted = false
    }

    func makeWebSocketRequest(languageCode: String?) throws -> URLRequest {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw AssemblyAIRealtimeSessionError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: String(configuration.sampleRate)),
            URLQueryItem(name: "speech_model", value: configuration.modelID),
            URLQueryItem(name: "mode", value: configuration.mode.rawValue),
        ]

        let languageCodes = normalizedLanguageCodes(override: languageCode)
        if !languageCodes.isEmpty {
            queryItems.append(URLQueryItem(name: "language_codes", value: try jsonArray(languageCodes)))
        }
        if !configuration.keyterms.isEmpty {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: try jsonArray(configuration.keyterms)))
        }
        if let prompt = configuration.prompt {
            queryItems.append(URLQueryItem(name: "prompt", value: prompt))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw AssemblyAIRealtimeSessionError.invalidURL
        }

        return try configuration.access.webSocketRequest(upstream: url)
    }

    func makeCommitMessage() throws -> String {
        try encodeMessage(AssemblyAIRealtimeAPI.forceEndpoint)
    }

    func makeTerminationMessage() throws -> String {
        try encodeMessage(AssemblyAIRealtimeAPI.terminate)
    }

    private func normalizedLanguageCodes(override: String?) -> [String] {
        guard let override else { return configuration.languageHints }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return configuration.languageHints }
        return [Locale.Language(identifier: trimmed).languageCode?.identifier.lowercased() ?? trimmed.lowercased()]
    }

    private func jsonArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AssemblyAIRealtimeSessionError.invalidMessage("Query array was not valid UTF-8")
        }
        return string
    }

    private func encodeMessage<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AssemblyAIRealtimeSessionError.invalidMessage("Encoded payload was not valid UTF-8")
        }
        return string
    }
}

extension AssemblyAIRealtimeSession: RealtimeTranscriptionSession {
    public nonisolated var sampleRate: Int { configuration.sampleRate }

    public nonisolated var finalizationTimeout: Duration { .seconds(5) }

    public func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        try await connect().realtimeTranscriptionEvents(Self.transcriptionEvents(from:))
    }

    public func disconnect() async {
        await disconnect(code: .normalClosure)
    }

    nonisolated static func transcriptionEvents(from event: AssemblyAIRealtimeEvent) -> [RealtimeTranscriptionEvent] {
        switch event {
        case .sessionStarted, .speechStarted, .partialTranscript:
            []
        case .committedTranscript(_, let text):
            [.committedTranscript(text)]
        case .sessionTerminated:
            [.finalizationCompleted]
        }
    }
}
