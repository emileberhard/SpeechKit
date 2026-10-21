import Foundation
import OSLog

public actor OpenAIRealtimeSession {
    private let logger = Logger(subsystem: "SpeechKit", category: "OpenAIRealtimeSession")
    private let configuration: OpenAIRealtimeSessionConfiguration
    private let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    private let connection: RealtimeWebSocketConnection<OpenAIRealtimeEvent>

    private var sentChunkCount = 0

    public init(
        configuration: OpenAIRealtimeSessionConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.connection = RealtimeWebSocketConnection(
            providerName: "OpenAI realtime",
            logger: logger,
            session: session ?? SpeechKitURLSessionFactory.realtimeSession(for: configuration.access),
            relay: configuration.access.relay,
            decodeEvent: OpenAIRealtimeAPI.decodeEvent(from:),
            isReadyEvent: { event in
                if case .sessionUpdated = event {
                    return true
                }
                return false
            },
            alreadyConnectedError: OpenAIRealtimeSessionError.alreadyConnected,
            notConnectedError: OpenAIRealtimeSessionError.notConnected,
            invalidMessageError: { OpenAIRealtimeSessionError.invalidMessage($0) }
        )
    }

    public func connect(languageCode: String? = nil) async throws -> AsyncThrowingStream<OpenAIRealtimeEvent, Error> {
        let request = try makeWebSocketRequest()
        let stream = try await connection.connect(request: request)
        sentChunkCount = 0

        do {
            try await connection.send(makeSessionUpdateMessage(languageCode: languageCode))
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

        let payload = OpenAIRealtimeAPI.AppendAudioPayload(audio: audioData.base64EncodedString())
        try await connection.send(try encodeMessage(payload))
        sentChunkCount += 1

        if sentChunkCount == 1 {
            logger.info("Sent first OpenAI realtime audio chunk (\(audioData.count, privacy: .public) bytes)")
        }
    }

    public func requestCommit() async throws {
        try await waitUntilReady()

        let payload = OpenAIRealtimeAPI.CommitAudioPayload()
        try await connection.send(try encodeMessage(payload))
        logger.info("Requested OpenAI realtime commit after \(self.sentChunkCount, privacy: .public) chunks")
    }

    public func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure) async {
        await connection.disconnect(code: code)
        sentChunkCount = 0
    }

    func makeWebSocketRequest() throws -> URLRequest {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OpenAIRealtimeSessionError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "intent", value: OpenAIRealtimeAPI.websocketIntent),
        ]

        guard let url = components.url else {
            throw OpenAIRealtimeSessionError.invalidURL
        }

        return try configuration.access.webSocketRequest(upstream: url)
    }

    func makeSessionUpdateMessage(languageCode: String?) throws -> String {
        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(
            configuration: configuration,
            languageCode: languageCode
        )
        return try encodeMessage(payload)
    }

    private func encodeMessage<T: Encodable>(_ payload: T) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeSessionError.invalidMessage("Encoded payload was not valid UTF-8")
        }
        return string
    }
}

extension OpenAIRealtimeSession: RealtimeTranscriptionSession {
    public nonisolated var sampleRate: Int { configuration.sampleRate }

    public nonisolated var finalizationTimeout: Duration { .seconds(5) }

    public func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        try await connect().realtimeTranscriptionEvents(tracking: OpenAIRealtimeCommits()) { commits, event in
            try commits.receive(event)
        }
    }

    public func disconnect() async {
        await disconnect(code: .normalClosure)
    }
}

struct OpenAIRealtimeCommits: Sendable {
    private var voiceActivityItemIDs: Set<String> = []
    private var isSpeaking = false
    private var committedItemIDs: [String] = []
    private var completedTranscripts: [String: String] = [:]
    private var deliveredItemCount = 0
    private var finalItemCount: Int?

    mutating func receive(_ event: OpenAIRealtimeEvent) throws -> [RealtimeTranscriptionEvent] {
        switch event {
        case .sessionUpdated, .partialTranscript:
            return []
        case .speechStarted:
            isSpeaking = true
            return []
        case .speechStopped(let itemID):
            isSpeaking = false
            voiceActivityItemIDs.insert(itemID)
            return []
        case .audioCommitted(let itemID):
            committedItemIDs.append(itemID)
            if voiceActivityItemIDs.remove(itemID) == nil {
                isSpeaking = false
                finalItemCount = committedItemIDs.count
            }
            return deliverCompletedItems()
        case .committedTranscript(let itemID, let transcript):
            completedTranscripts[itemID] = transcript
            return deliverCompletedItems()
        case .commitRejected(let message):
            guard !isSpeaking else { throw OpenAIRealtimeSessionError.server(message: message) }
            finalItemCount = committedItemIDs.count
            return deliverCompletedItems()
        }
    }

    private mutating func deliverCompletedItems() -> [RealtimeTranscriptionEvent] {
        var events: [RealtimeTranscriptionEvent] = []
        while deliveredItemCount < committedItemIDs.count,
              let transcript = completedTranscripts.removeValue(forKey: committedItemIDs[deliveredItemCount]) {
            events.append(.committedTranscript(transcript))
            deliveredItemCount += 1
        }
        if let finalItemCount, deliveredItemCount >= finalItemCount {
            events.append(.finalizationCompleted)
            self.finalItemCount = nil
        }
        return events
    }
}
