import CryptoKit
import Foundation
import Network
import OSLog
import Testing
@testable import SpeechKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SpeechRelayTests {
    @Test func rejectsRelayURLsAndTokensThatCannotBeSentSafely() {
        for url in [
            "ftp://gateway.test/speech/openai",
            "https://user:secret@gateway.test/speech/openai",
            "https://gateway.test/speech/openai?key=value",
            "https://gateway.test/speech/openai#fragment",
        ] {
            #expect(throws: SpeechKitError.self) {
                try SpeechRelay(baseURL: URL(string: url)!, bearerToken: "rc1.token")
            }
        }
        for token in ["", "two words", "line\nbreak"] {
            #expect(throws: SpeechKitError.self) {
                try SpeechRelay(baseURL: URL(string: "https://gateway.test/speech/openai")!, bearerToken: token)
            }
        }
    }

    @Test func realtimeSessionsConnectThroughTheRelayWithoutProviderCredentials() async throws {
        let openAI = try await OpenAIRealtimeSession(
            configuration: .init(access: Self.relay("openai"))
        ).makeWebSocketRequest()
        let elevenLabs = try await ElevenLabsRealtimeSession(
            configuration: .init(access: Self.relay("elevenlabs"))
        ).makeWebSocketRequest(languageCode: "sv")
        let gemini = try await GeminiRealtimeSession(
            configuration: .init(access: Self.relay("gemini"))
        ).makeWebSocketRequest()
        let assemblyAI = try await AssemblyAIRealtimeSession(
            configuration: .init(access: Self.relay("assemblyai"))
        ).makeWebSocketRequest(languageCode: nil)

        #expect(openAI.url?.absoluteString == "wss://gateway.test:8787/speech/openai/v1/realtime?intent=transcription")
        #expect(
            gemini.url?.absoluteString
                == "wss://gateway.test:8787/speech/gemini/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        #expect(elevenLabs.url?.path == "/speech/elevenlabs/v1/speech-to-text/realtime")
        #expect(Self.queryValue("language_code", in: elevenLabs) == "sv")
        #expect(Self.queryValue("model_id", in: elevenLabs) == "scribe_v2_realtime")
        #expect(assemblyAI.url?.path == "/speech/assemblyai/v3/ws")
        #expect(Self.queryValue("speech_model", in: assemblyAI) == "universal-3-5-pro")

        for request in [openAI, elevenLabs, gemini, assemblyAI] {
            #expect(request.url?.scheme == "wss")
            #expect(request.url?.host == "gateway.test")
            #expect(request.url?.port == 8787)
            #expect(Self.queryValue("key", in: request) == nil)
            #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer rc1.installation"])
        }
    }

    @Test func plainHTTPRelayUsesPlainWebSocketAndIgnoresTrailingSlash() async throws {
        let access = SpeechProviderAccess.relay(
            try SpeechRelay(baseURL: URL(string: "http://gateway.internal.test:8787/speech/openai/")!, bearerToken: "rc1.token")
        )
        let request = try await OpenAIRealtimeSession(configuration: .init(access: access)).makeWebSocketRequest()

        #expect(request.url?.absoluteString == "ws://gateway.internal.test:8787/speech/openai/v1/realtime?intent=transcription")
    }

    @Test func batchTranscriptionPostsToTheRelay() async throws {
        let capture = RelayRequestCapture()
        RelayMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(for: request, body: Data(#"{"text":"Hej Stockholm."}"#.utf8))
        }
        defer { RelayMockURLProtocol.handlerStore.set(nil) }

        let provider = OpenAITranscriptionProvider(
            configuration: try .init(access: Self.relay("openai"), model: "gpt-4o-transcribe"),
            session: Self.makeSession()
        )
        let result = try await provider.transcribe(Self.transcriptionRequest(fileExtension: "m4a"))

        #expect(result.text == "Hej Stockholm.")
        let request = try #require(capture.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://gateway.test:8787/speech/openai/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rc1.installation")
    }

    @Test func providersReachTheRelayThroughItsTransportAndShareItsSessions() async throws {
        let capture = RelayRequestCapture()
        RelayMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            let body = request.url?.path.hasSuffix(":generateContent") == true
                ? #"{"candidates":[{"content":{"parts":[{"text":"Hej Stockholm."}]}}]}"#
                : #"{"text":"Hej Stockholm."}"#
            return Self.response(for: request, body: Data(body.utf8))
        }
        defer { RelayMockURLProtocol.handlerStore.set(nil) }
        let transport = SpeechRelayTransport(
            configure: { $0.protocolClasses = [RelayMockURLProtocol.self] },
            acceptsServerTrust: { _ in false }
        )
        func access(_ provider: String) throws -> SpeechProviderAccess {
            .relay(try SpeechRelay(
                baseURL: URL(string: "https://gateway.test:8787/speech/\(provider)")!,
                bearerToken: "rc1.installation",
                transport: transport
            ))
        }

        let openAI = OpenAITranscriptionProvider(configuration: try .init(access: access("openai"), model: "gpt-4o-transcribe"))
        let gemini = GeminiTranscriptionProvider(configuration: try .init(access: access("gemini")))
        #expect(try await openAI.transcribe(Self.transcriptionRequest(fileExtension: "m4a")).text == "Hej Stockholm.")
        #expect(try await gemini.transcribe(Self.transcriptionRequest(fileExtension: "wav")).text == "Hej Stockholm.")

        #expect(capture.requests.map { $0.url?.host } == ["gateway.test", "gateway.test"])
        let relay = try access("openai")
        #expect(SpeechKitURLSessionFactory.batchSession(for: relay) === SpeechKitURLSessionFactory.batchSession(for: relay))
        #expect(SpeechKitURLSessionFactory.realtimeSession(for: relay) !== SpeechKitURLSessionFactory.batchSession(for: relay))
    }

    @Test func azureRelayCarriesNoResourceEndpointOrSubscriptionKey() async throws {
        let capture = RelayRequestCapture()
        RelayMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(for: request, body: Data(#"{"combinedPhrases":[{"text":"Hej Stockholm."}]}"#.utf8))
        }
        defer { RelayMockURLProtocol.handlerStore.set(nil) }

        let provider = AzureSpeechTranscriptionProvider(
            configuration: try .init(access: .relay(Self.speechRelay("azure"))),
            session: Self.makeSession()
        )
        let result = try await provider.transcribe(Self.transcriptionRequest(fileExtension: "wav"))

        #expect(result.text == "Hej Stockholm.")
        let request = try #require(capture.requests.first)
        #expect(
            request.url?.absoluteString
                == "https://gateway.test:8787/speech/azure/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rc1.installation")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == nil)
    }

    @Test func surfacesARejectedWebSocketUpgradeAsItsHTTPStatus() async throws {
        let error = try await Self.webSocketFailure(relay: Self.speechRelay("openai")) { _ in
            Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        }
        guard case .webSocketHandshakeFailed(401) = error else {
            Issue.record("Expected the upgrade status, got \(error)")
            return
        }
    }

    @Test func surfacesTheServerCloseCodeAndReason() async throws {
        let error = try await Self.webSocketFailure(relay: Self.speechRelay("openai")) { request in
            Self.upgradeResponse(for: request) + Self.closeFrame(code: 4403, reason: "notPermitted")
        }
        guard case .webSocketClosed(4403, "notPermitted") = error else {
            Issue.record("Expected the provider close, got \(error)")
            return
        }
    }

    @Test func relayMarkedWebSocketRejectionsBecomeTypedRelayErrors() async throws {
        let refusedUpgrade: @Sendable (String) -> Data = { _ in
            Data(
                "HTTP/1.1 503 Service Unavailable\r\nX-Speech-Relay-Rejection: providerNotConfigured\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
            )
        }
        let closed: @Sendable (String) -> Data = { request in
            Self.upgradeResponse(for: request)
                + Self.closeFrame(code: 4401, reason: "speech-relay-rejection:unauthorized")
        }

        let relayedUpgrade = try await Self.webSocketFailure(relay: Self.speechRelay("openai"), respond: refusedUpgrade)
        guard case .relayRejected("providerNotConfigured") = relayedUpgrade else {
            Issue.record("Expected the relay rejection, got \(relayedUpgrade)")
            return
        }
        let relayedClose = try await Self.webSocketFailure(relay: Self.speechRelay("openai"), respond: closed)
        guard case .relayRejected("unauthorized") = relayedClose else {
            Issue.record("Expected the relay rejection, got \(relayedClose)")
            return
        }

        let routedUpgrade = try await Self.webSocketFailure(relay: nil, respond: refusedUpgrade)
        guard case .webSocketHandshakeFailed(503) = routedUpgrade else {
            Issue.record("A router connection must not read relay markers, got \(routedUpgrade)")
            return
        }
        let routedClose = try await Self.webSocketFailure(relay: nil, respond: closed)
        guard case .webSocketClosed(4401, "speech-relay-rejection:unauthorized") = routedClose else {
            Issue.record("A router connection must not read relay markers, got \(routedClose)")
            return
        }
    }

    @Test func relayMarkedHTTPRejectionsBecomeTypedRelayErrors() async throws {
        RelayMockURLProtocol.handlerStore.set { request in
            Self.relayRejection(for: request, kind: "capacity", status: 429)
        }
        defer { RelayMockURLProtocol.handlerStore.set(nil) }

        let relayed = try await #require(throws: SpeechKitError.self) {
            _ = try await OpenAITranscriptionProvider(
                configuration: try .init(access: Self.relay("openai"), model: "gpt-4o-transcribe"),
                session: Self.makeSession()
            ).transcribe(Self.transcriptionRequest(fileExtension: "m4a"))
        }
        guard case .relayRejected("capacity") = relayed else {
            Issue.record("Expected the relay rejection, got \(relayed)")
            return
        }

        let routed = try await #require(throws: SpeechKitError.self) {
            _ = try await OpenAITranscriptionProvider(
                configuration: try .init(access: .testRouter(), model: "gpt-4o-transcribe"),
                session: Self.makeSession()
            ).transcribe(Self.transcriptionRequest(fileExtension: "m4a"))
        }
        guard case .httpFailure(429, _) = routed else {
            Issue.record("A router request must not read relay markers, got \(routed)")
            return
        }
    }

    @Test func azureProgressiveUploadReportsRelayRejectionsAndKeepsProviderTextOut() async throws {
        RelayMockURLProtocol.handlerStore.set { request in
            Self.relayRejection(for: request, kind: "requestTooLarge", status: 413)
        }
        defer { RelayMockURLProtocol.handlerStore.set(nil) }

        let relayed = try await Self.progressiveFailure(access: .relay(Self.speechRelay("azure")))
        guard case .relayRejected("requestTooLarge") = relayed else {
            Issue.record("Expected the relay rejection, got \(relayed)")
            return
        }

        let routed = try await Self.progressiveFailure(access: .testRouter())
        guard case .httpFailure(413, let body) = routed else {
            Issue.record("A router upload must not read relay markers, got \(routed)")
            return
        }
        #expect(!body.contains("sensitive"))
    }

    private static func speechRelay(_ provider: String) throws -> SpeechRelay {
        try SpeechRelay(
            baseURL: URL(string: "https://gateway.test:8787/speech/\(provider)")!,
            bearerToken: "rc1.installation"
        )
    }

    private static func relay(_ provider: String) throws -> SpeechProviderAccess {
        .relay(try speechRelay(provider))
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    private static func transcriptionRequest(fileExtension: String) throws -> TranscriptionRequest {
        TranscriptionRequest(
            audio: try TranscriptionAudio(
                data: Data([0x01, 0x02]),
                fileName: "recording.\(fileExtension)",
                mimeType: "audio/\(fileExtension)",
                fileExtension: fileExtension
            ),
            languageHints: [],
            customVocabulary: []
        )
    }

    private static func webSocketFailure(
        relay: SpeechRelay?,
        respond: @escaping @Sendable (String) -> Data
    ) async throws -> SpeechKitError {
        let server = try OneShotWebSocketServer(respond: respond)
        let port = try await server.start()
        defer { server.stop() }
        return try await #require(throws: SpeechKitError.self) {
            try await drain(port: port, relay: relay)
        }
    }

    private static func progressiveFailure(access: SpeechProviderAccess) async throws -> SpeechKitError {
        let provider = AzureSpeechTranscriptionProvider(
            configuration: try .init(access: access),
            session: makeSession()
        )
        let session = try await provider.startProgressiveTranscription(.init())
        return try await #require(throws: SpeechKitError.self) {
            try await session.appendAudio(Data(count: 3_200))
            _ = try await session.finish()
        }
    }

    private static func relayRejection(for request: URLRequest, kind: String, status: Int) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["X-Speech-Relay-Rejection": kind, "Content-Type": "application/json"]
            )!,
            Data(#"{"error":"sensitive request text"}"#.utf8)
        )
    }

    private static func drain(port: UInt16, relay: SpeechRelay?) async throws {
        let connection = RealtimeWebSocketConnection<Data>(
            providerName: "Relay test",
            logger: Logger(subsystem: "SpeechKitTests", category: "SpeechRelayTests"),
            session: URLSession(configuration: .ephemeral),
            relay: relay,
            decodeEvent: { $0 },
            isReadyEvent: { _ in true },
            alreadyConnectedError: SpeechKitError.invalidResponse,
            notConnectedError: SpeechKitError.invalidResponse,
            invalidMessageError: { SpeechKitError.providerFailure($0) },
            pingIntervalNanoseconds: nil
        )
        let stream = try await connection.connect(request: URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!))
        for try await _ in stream {}
    }

    private static func upgradeResponse(for request: String) -> Data {
        let key = request
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        return Data(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8
        )
    }

    private static func closeFrame(code: UInt16, reason: String) -> Data {
        let payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)]) + Data(reason.utf8)
        return Data([0x88, UInt8(payload.count)]) + payload
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, body)
    }
}

private final class OneShotWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SpeechKitTests.OneShotWebSocketServer")

    init(respond: @escaping @Sendable (String) -> Data) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                connection.send(content: respond(request), completion: .contentProcessed { _ in })
            }
        }
    }

    func start() async throws -> UInt16 {
        let listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: SpeechKitError.invalidResponse)
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}

private final class RelayMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    static let handlerStore = RelayHandlerStore()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handlerStore.get() else {
                throw SpeechKitError.invalidConfiguration("Missing test URL handler")
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RelayHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: RelayMockURLProtocol.Handler?

    func set(_ handler: RelayMockURLProtocol.Handler?) {
        lock.withLock { self.handler = handler }
    }

    func get() -> RelayMockURLProtocol.Handler? {
        lock.withLock { handler }
    }
}

private final class RelayRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
