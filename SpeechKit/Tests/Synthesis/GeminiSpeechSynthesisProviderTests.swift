import Foundation
import Testing
@testable import SpeechKit

@Suite(.serialized)
struct GeminiSpeechSynthesisProviderTests {
    init() {
        MockURLProtocol.handlerStore.set(nil)
    }

    @Test func generateContentStreamsAudioAndSendsTypedGenerationOptions() async throws {
        let capture = RequestCapture()
        MockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(
                for: request,
                statusCode: 200,
                body: Self.generateContentAudioStream([
                    Data([0x01, 0x02]),
                    Data([0x03, 0x04]),
                ])
            )
        }

        let provider = try makeProvider(retryCount: 0)
        let options = try GeminiSpeechSynthesisOptions(
            voice: .achird,
            instructions: "Friendly and conversational."
        )
        let synthesisRequest = SpeechSynthesisRequest(text: "Hello there.", options: options)
        let encodedRequest = try provider.makeURLRequest(for: synthesisRequest)
        let stream = provider.synthesize(synthesisRequest)

        var audio = Data()
        for try await chunk in stream {
            #expect(chunk.format == .pcm16Mono24kHz)
            audio.append(chunk.data)
        }

        #expect(audio == Data([0x01, 0x02, 0x03, 0x04]))
        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Api-Revision") == nil)
        #expect(request.url?.path == "/vendors/google/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent")
        #expect(
            URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "alt" })?.value == "sse"
        )

        let bodyData = try #require(encodedRequest.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let generation = try #require(body["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        let speech = try #require(generation["speechConfig"] as? [String: Any])
        let voice = try #require(speech["voiceConfig"] as? [String: Any])
        let prebuilt = try #require(voice["prebuiltVoiceConfig"] as? [String: Any])
        #expect(prebuilt["voiceName"] as? String == "Achird")

        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let prompt = try #require(parts.first?["text"] as? String)
        #expect(prompt.contains("DIRECTOR'S NOTES:\nFriendly and conversational."))
        #expect(prompt.contains("TRANSCRIPT:\nHello there."))
    }

    @Test func interactionsStreamsAudioAndSendsTypedGenerationOptions() async throws {
        let capture = RequestCapture()
        MockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(
                for: request,
                statusCode: 200,
                body: Self.interactionAudioStream([
                    Data([0x01, 0x02]),
                    Data([0x03, 0x04]),
                ])
            )
        }

        let provider = try makeProvider(retryCount: 0, transport: .interactions)
        let options = try GeminiSpeechSynthesisOptions(
            voice: .achird,
            instructions: "Friendly and conversational."
        )
        let synthesisRequest = SpeechSynthesisRequest(text: "Hello there.", options: options)
        let encodedRequest = try provider.makeURLRequest(for: synthesisRequest)

        var audio = Data()
        for try await chunk in provider.synthesize(synthesisRequest) {
            audio.append(chunk.data)
        }

        #expect(audio == Data([0x01, 0x02, 0x03, 0x04]))
        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Api-Revision") == "2026-05-20")
        #expect(request.url?.path == "/vendors/google/v1beta/interactions")

        let bodyData = try #require(encodedRequest.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        #expect(body["model"] as? String == "gemini-3.1-flash-tts-preview")
        #expect(body["stream"] as? Bool == true)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "audio")

        let generation = try #require(body["generation_config"] as? [String: Any])
        let voices = try #require(generation["speech_config"] as? [[String: Any]])
        #expect(voices.first?["voice"] as? String == "Achird")
    }

    @Test func retriesDocumentedTransientServerFailure() async throws {
        let attempts = AttemptCounter()
        MockURLProtocol.handlerStore.set { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                return Self.response(for: request, statusCode: 500, body: Data("temporary".utf8))
            }
            return Self.response(
                for: request,
                statusCode: 200,
                body: Self.generateContentAudioStream([Data([0x01, 0x02])])
            )
        }

        let provider = try makeProvider(retryCount: 1)
        let options = try GeminiSpeechSynthesisOptions()
        var chunks: [SpeechAudioChunk] = []
        for try await chunk in provider.synthesize(
            SpeechSynthesisRequest(text: "Retry me.", options: options)
        ) {
            chunks.append(chunk)
        }

        #expect(attempts.value == 2)
        #expect(chunks.count == 1)
    }

    @Test func retriesGenericInvalidArgumentFailure() async throws {
        let attempts = AttemptCounter()
        MockURLProtocol.handlerStore.set { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                let body = """
                    {
                      "error": {
                        "code": 400,
                        "message": "Request contains an invalid argument.",
                        "status": "INVALID_ARGUMENT"
                      }
                    }
                    """
                return Self.response(for: request, statusCode: 400, body: Data(body.utf8))
            }
            return Self.response(
                for: request,
                statusCode: 200,
                body: Self.generateContentAudioStream([Data([0x01, 0x02])])
            )
        }

        let provider = try makeProvider(retryCount: 1)
        let options = try GeminiSpeechSynthesisOptions()
        var chunks: [SpeechAudioChunk] = []
        for try await chunk in provider.synthesize(
            SpeechSynthesisRequest(text: "Retry the transient rejection.", options: options)
        ) {
            chunks.append(chunk)
        }

        #expect(attempts.value == 2)
        #expect(chunks.count == 1)
    }

    @Test func doesNotRetrySpecificInvalidArgumentFailure() async throws {
        let attempts = AttemptCounter()
        MockURLProtocol.handlerStore.set { request in
            _ = attempts.increment()
            let body = """
                {
                  "error": {
                    "code": 400,
                    "message": "Voice name is invalid.",
                    "status": "INVALID_ARGUMENT"
                  }
                }
                """
            return Self.response(for: request, statusCode: 400, body: Data(body.utf8))
        }

        let provider = try makeProvider(retryCount: 1)
        let options = try GeminiSpeechSynthesisOptions()

        do {
            for try await _ in provider.synthesize(
                SpeechSynthesisRequest(text: "Do not retry this.", options: options)
            ) {}
            Issue.record("Expected the specific invalid argument failure")
        } catch SpeechKitError.httpFailure(let statusCode, _) {
            #expect(statusCode == 400)
        }

        #expect(attempts.value == 1)
    }

    @Test func rejectsEmptySpeechTextBeforeNetworkRequest() async throws {
        let capture = RequestCapture()
        MockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(for: request, statusCode: 200, body: Data())
        }

        let provider = try makeProvider(retryCount: 0)
        let options = try GeminiSpeechSynthesisOptions()

        do {
            for try await _ in provider.synthesize(
                SpeechSynthesisRequest(text: "  \n", options: options)
            ) {}
            Issue.record("Expected empty speech text to fail")
        } catch SpeechKitError.invalidRequest {
            #expect(capture.requests.isEmpty)
        }
    }

    private func makeProvider(
        retryCount: Int,
        transport: GeminiSpeechSynthesisTransport = .generateContent
    ) throws -> GeminiSpeechSynthesisProvider {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        return GeminiSpeechSynthesisProvider(
            configuration: try GeminiSpeechSynthesisConfiguration(
                access: .testRouter(),
                retryCount: retryCount,
                transport: transport
            ),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int,
        body: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, body)
    }

    private static func interactionAudioStream(_ chunks: [Data]) -> Data {
        var events = chunks.map { chunk in
            "event: step.delta\ndata: {\"event_type\":\"step.delta\",\"delta\":{\"type\":\"audio\",\"data\":\"\(chunk.base64EncodedString())\"}}\n"
        }
        events.append("event: done\ndata: [DONE]\n")
        return Data(events.joined(separator: "\n").utf8)
    }

    private static func generateContentAudioStream(_ chunks: [Data]) -> Data {
        let events = chunks.map { chunk in
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/l16; rate=24000; channels=1\",\"data\":\"\(chunk.base64EncodedString())\"}}]}}]}\n"
        }
        return Data(events.joined(separator: "\n").utf8)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    static let handlerStore = HandlerStore()

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

private final class HandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: MockURLProtocol.Handler?

    func set(_ handler: MockURLProtocol.Handler?) {
        lock.withLock {
            self.handler = handler
        }
    }

    func get() -> MockURLProtocol.Handler? {
        lock.withLock { handler }
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock {
            storage.append(request)
        }
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}
