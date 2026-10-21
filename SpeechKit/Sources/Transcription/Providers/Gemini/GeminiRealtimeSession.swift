import Foundation
import OSLog

public actor GeminiRealtimeSession {
    private let logger = Logger(subsystem: "SpeechKit", category: "GeminiRealtimeSession")
    private let configuration: GeminiRealtimeSessionConfiguration
    private let endpoint = URL(
        string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )!
    private let connection: RealtimeWebSocketConnection<GeminiRealtimeEvent>

    private var hasStartedActivity = false
    private var sentChunkCount = 0

    public init(
        configuration: GeminiRealtimeSessionConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.connection = RealtimeWebSocketConnection(
            providerName: "Gemini realtime",
            logger: logger,
            session: session ?? SpeechKitURLSessionFactory.realtimeSession(for: configuration.access),
            relay: configuration.access.relay,
            decodeEvent: GeminiRealtimeAPI.decodeEvent(from:),
            isReadyEvent: { event in
                if case .setupComplete = event {
                    return true
                }
                return false
            },
            alreadyConnectedError: GeminiRealtimeSessionError.alreadyConnected,
            notConnectedError: GeminiRealtimeSessionError.notConnected,
            invalidMessageError: { GeminiRealtimeSessionError.invalidMessage($0) }
        )
    }

    public func connect(languageCode: String? = nil) async throws -> AsyncThrowingStream<GeminiRealtimeEvent, Error> {
        let request = try makeWebSocketRequest()
        let stream = try await connection.connect(request: request)
        hasStartedActivity = false
        sentChunkCount = 0

        do {
            try await connection.send(makeSetupMessage(languageCode: languageCode))
        } catch {
            await connection.disconnect(code: .goingAway)
            throw error
        }

        return stream
    }

    public func waitUntilReady() async throws {
        try await connection.waitUntilReady()
    }

    public func sendAudioChunk(_ audioData: Data) async throws {
        guard !audioData.isEmpty else { return }

        try await waitUntilReady()
        if !hasStartedActivity {
            try await connection.send(try encodeMessage(GeminiRealtimeAPI.ActivityStartPayload()))
            hasStartedActivity = true
        }

        try await connection.send(
            try encodeMessage(
                GeminiRealtimeAPI.audioPayload(audioData, sampleRate: configuration.sampleRate)
            )
        )
        sentChunkCount += 1

        if sentChunkCount == 1 {
            logger.info("Sent first Gemini realtime audio chunk (\(audioData.count, privacy: .public) bytes)")
        }
    }

    public func requestCommit() async throws {
        try await waitUntilReady()
        guard hasStartedActivity else { return }

        try await connection.send(try encodeMessage(GeminiRealtimeAPI.ActivityEndPayload()))
        hasStartedActivity = false
        logger.info("Ended Gemini realtime activity after \(self.sentChunkCount, privacy: .public) chunks")
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        await connection.disconnect(code: code)
        hasStartedActivity = false
        sentChunkCount = 0
    }

    func makeWebSocketRequest() throws -> URLRequest {
        try configuration.access.webSocketRequest(upstream: endpoint)
    }

    func makeSetupMessage(languageCode: String?) throws -> String {
        try encodeMessage(
            GeminiRealtimeAPI.setupPayload(
                configuration: configuration,
                languageCode: languageCode
            )
        )
    }

    func makeAudioMessage(_ data: Data) throws -> String {
        try encodeMessage(GeminiRealtimeAPI.audioPayload(data, sampleRate: configuration.sampleRate))
    }

    func makeActivityStartMessage() throws -> String {
        try encodeMessage(GeminiRealtimeAPI.ActivityStartPayload())
    }

    func makeActivityEndMessage() throws -> String {
        try encodeMessage(GeminiRealtimeAPI.ActivityEndPayload())
    }

    private func encodeMessage<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw GeminiRealtimeSessionError.invalidMessage("Encoded payload was not valid UTF-8")
        }
        return string
    }
}

extension GeminiRealtimeSession: RealtimeTranscriptionSession {
    public nonisolated var sampleRate: Int { configuration.sampleRate }

    public nonisolated var finalizationTimeout: Duration { .seconds(5) }

    public func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        try await connect().realtimeTranscriptionEvents(Self.transcriptionEvents(from:))
    }

    public func disconnect() async {
        await disconnect(code: .normalClosure)
    }

    nonisolated static func transcriptionEvents(from event: GeminiRealtimeEvent) -> [RealtimeTranscriptionEvent] {
        switch event {
        case .setupComplete, .partialTranscript:
            []
        case .committedTranscript(let text):
            [.committedTranscript(text), .finalizationCompleted]
        }
    }
}
