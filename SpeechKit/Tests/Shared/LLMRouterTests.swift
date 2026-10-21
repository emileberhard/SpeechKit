import Foundation
import Testing
@testable import SpeechKit

extension SpeechProviderAccess {
    static func testRouter() throws -> SpeechProviderAccess {
        .router(try LLMRouter(origin: URL(string: "https://router.test")!, key: "llmr_test"))
    }
}

@Suite(.serialized)
struct LLMRouterTests {
    @Test func rejectsOriginsAndKeysThatCannotBeSentSafely() {
        for origin in [
            "ftp://router.test",
            "https://user:secret@router.test",
            "https://router.test/v1",
            "https://router.test?key=value",
            "https://router.test#fragment",
        ] {
            #expect(throws: SpeechKitError.self) {
                try LLMRouter(origin: URL(string: origin)!, key: "llmr_test")
            }
        }
        for key in ["", "two words", "line\nbreak"] {
            #expect(throws: SpeechKitError.self) {
                try LLMRouter(origin: URL(string: "https://router.test")!, key: key)
            }
        }
    }

    @Test func batchProvidersUseTheRouterRouteForTheirVendor() async throws {
        let capture = RouterRequestCapture()
        RouterMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: [:])!, Data())
        }
        defer { RouterMockURLProtocol.handlerStore.set(nil) }
        let session = Self.makeSession()
        let wav = try Self.request(fileExtension: "wav")
        let m4a = try Self.request(fileExtension: "m4a")

        let providers: [(any TranscriptionProvider, TranscriptionRequest)] = [
            (OpenAITranscriptionProvider(configuration: try .init(access: .testRouter(), model: "gpt-4o-transcribe"), session: session), m4a),
            (ElevenLabsTranscriptionProvider(configuration: .init(access: try .testRouter()), session: session), m4a),
            (AzureSpeechTranscriptionProvider(configuration: try .init(access: .testRouter()), session: session), wav),
        ]
        for (provider, request) in providers {
            await #expect(throws: SpeechKitError.self) { _ = try await provider.transcribe(request) }
        }

        #expect(capture.requests.map { $0.url?.absoluteString } == [
            "https://router.test/v1/audio/transcriptions",
            "https://router.test/vendors/elevenlabs/v1/speech-to-text",
            "https://router.test/vendors/azure-speech/speechtotext/transcriptions:transcribe?api-version=2025-10-15",
        ])
        for request in capture.requests {
            Self.expectOnlyRouterCredential(request)
        }
    }

    @Test(arguments: [
        ("https://api.openai.com/v1/audio/transcriptions", "https://router.test/v1/audio/transcriptions"),
        ("wss://api.openai.com/v1/realtime?intent=transcription", "https://router.test/vendors/openai/v1/realtime?intent=transcription"),
        ("https://api.elevenlabs.io/v1/speech-to-text", "https://router.test/vendors/elevenlabs/v1/speech-to-text"),
        ("https://api.assemblyai.com/v2/transcript/abc", "https://router.test/vendors/assemblyai/v2/transcript/abc"),
        ("wss://streaming.assemblyai.com/v3/ws?sample_rate=16000", "https://router.test/vendors/assemblyai-streaming/v3/ws?sample_rate=16000"),
        (
            "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc",
            "https://router.test/vendors/google/upload/v1beta/files?upload_id=abc"
        ),
    ])
    func mapsEachProviderHostToItsRouterRoute(upstream: String, routed: String) throws {
        let request = try SpeechProviderAccess.testRouter().request(upstream: URL(string: upstream)!)

        #expect(request.url?.absoluteString == routed)
        Self.expectOnlyRouterCredential(request)
    }

    @Test func speechSynthesisUsesTheGoogleVendorRoute() throws {
        let provider = GeminiSpeechSynthesisProvider(
            configuration: try .init(access: .testRouter()),
            session: Self.makeSession()
        )
        let request = try provider.makeURLRequest(
            for: SpeechSynthesisRequest(text: "Hej Stockholm.", options: GeminiSpeechSynthesisOptions())
        )

        #expect(
            request.url?.absoluteString
                == "https://router.test/vendors/google/v1beta/models/gemini-3.1-flash-tts-preview:streamGenerateContent?alt=sse"
        )
        Self.expectOnlyRouterCredential(request)
    }

    @Test func refusesUpstreamsTheRouterDoesNotProxy() throws {
        #expect(throws: SpeechKitError.self) {
            try SpeechProviderAccess.testRouter().request(upstream: URL(string: "https://api.example.test/v1/audio")!)
        }
    }

    private static func expectOnlyRouterCredential(_ request: URLRequest) {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer llmr_test")
        for header in ["x-goog-api-key", "xi-api-key", "Ocp-Apim-Subscription-Key", "x-api-key"] {
            #expect(request.value(forHTTPHeaderField: header) == nil)
        }
        #expect(request.url?.query?.contains("key=") != true)
    }

    private static func request(fileExtension: String) throws -> TranscriptionRequest {
        TranscriptionRequest(
            audio: try TranscriptionAudio(
                data: Data([0x01, 0x02]),
                fileName: "recording.\(fileExtension)",
                mimeType: "audio/\(fileExtension)",
                fileExtension: fileExtension
            ),
            languageHints: ["sv"],
            customVocabulary: ["Stockholm"]
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RouterMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class RouterMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    static let handlerStore = RouterHandlerStore()

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

private final class RouterHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: RouterMockURLProtocol.Handler?

    func set(_ handler: RouterMockURLProtocol.Handler?) {
        lock.withLock { self.handler = handler }
    }

    func get() -> RouterMockURLProtocol.Handler? {
        lock.withLock { handler }
    }
}

private final class RouterRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
