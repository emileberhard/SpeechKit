import Foundation
import Testing
@testable import SpeechKit

@Suite(.serialized)
struct GeminiTranscribeTests {
    @Test func transcribesThroughFilesAndStatelessInteraction() async throws {
        let capture = GeminiRequestCapture()
        GeminiTranscribeMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            switch (request.url?.path, request.url?.query) {
            case ("/vendors/google/upload/v1beta/files", nil):
                return Self.response(
                    for: request,
                    headers: [
                        "X-Goog-Upload-URL":
                            "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc&upload_protocol=resumable"
                    ]
                )
            case ("/vendors/google/upload/v1beta/files", "upload_id=abc&upload_protocol=resumable"):
                return Self.response(
                    for: request,
                    body: Data(#"{"file":{"name":"files/test-file","uri":"https://files.test/test-file"}}"#.utf8)
                )
            case ("/vendors/google/v1beta/interactions", nil):
                return Self.response(
                    for: request,
                    body: Data(#"{"steps":[{"content":[{"type":"text","text":"Hej Stockholm."}]}]}"#.utf8)
                )
            case ("/vendors/google/v1beta/files/test-file", nil):
                return Self.response(for: request)
            default:
                return Self.response(for: request, statusCode: 404)
            }
        }
        defer { GeminiTranscribeMockURLProtocol.handlerStore.set(nil) }

        let provider = GeminiTranscribeProvider(
            configuration: try GeminiTranscribeProviderConfiguration(
                access: .testRouter(),
                mode: .smart
            ),
            session: Self.makeSession()
        )
        let audio = try TranscriptionAudio(
            data: Data([0x01, 0x02]),
            fileName: "recording.wav",
            mimeType: "audio/wav",
            fileExtension: "wav"
        )
        let transcriptionRequest = TranscriptionRequest(
            audio: audio,
            languageHints: ["sv", "en"],
            customVocabulary: [" SpeechKit ", "Stockholm", ""]
        )
        let encodedInteraction = try provider.makeInteractionRequest(
            fileURI: "https://files.test/test-file",
            request: transcriptionRequest
        )

        let result = try await provider.transcribe(transcriptionRequest)

        #expect(result.text == "Hej Stockholm.")
        #expect(result.providerID == "gemini-transcribe")
        #expect(capture.requests.map(\.url?.path) == [
            "/vendors/google/upload/v1beta/files",
            "/vendors/google/upload/v1beta/files",
            "/vendors/google/v1beta/interactions",
            "/vendors/google/v1beta/files/test-file",
        ])
        for request in capture.requests {
            #expect(request.url?.host == "router.test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer llmr_test")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
        }

        let body = try #require(encodedInteraction.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "gemini-3.5-transcribe")
        #expect(object["store"] as? Bool == false)

        let generation = try #require(object["generation_config"] as? [String: Any])
        let transcription = try #require(generation["transcription_config"] as? [String: Any])
        #expect(transcription["language_codes"] as? [String] == ["sv-SE", "en-US"])
        #expect(transcription["custom_vocabulary"] as? [String] == ["SpeechKit", "Stockholm"])
        #expect((transcription["mode"] as? [String: Any])?["type"] as? String == "smart")

        let deleteRequest = try #require(capture.requests.last)
        #expect(deleteRequest.httpMethod == "DELETE")
    }

    @Test func routesTheResumableUploadSessionThroughTheRelay() async throws {
        let capture = GeminiRequestCapture()
        GeminiTranscribeMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            switch (request.url?.path, request.url?.query) {
            case ("/speech/gemini/upload/v1beta/files", nil):
                return Self.response(
                    for: request,
                    headers: [
                        "X-Goog-Upload-URL":
                            "https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=abc&upload_protocol=resumable"
                    ]
                )
            case ("/speech/gemini/upload/v1beta/files", "upload_id=abc&upload_protocol=resumable"):
                return Self.response(
                    for: request,
                    body: Data(#"{"file":{"name":"files/test-file","uri":"https://files.test/test-file"}}"#.utf8)
                )
            case ("/speech/gemini/v1beta/interactions", nil):
                return Self.response(
                    for: request,
                    body: Data(#"{"steps":[{"content":[{"type":"text","text":"Hej Stockholm."}]}]}"#.utf8)
                )
            case ("/speech/gemini/v1beta/files/test-file", nil):
                return Self.response(for: request)
            default:
                return Self.response(for: request, statusCode: 404)
            }
        }
        defer { GeminiTranscribeMockURLProtocol.handlerStore.set(nil) }

        let result = try await Self.relayProvider().transcribe(Self.request())

        #expect(result.text == "Hej Stockholm.")
        #expect(capture.requests.count == 4)
        for request in capture.requests {
            #expect(request.url?.host == "gateway.test")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer rc1.installation")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
        }
    }

    @Test func refusesAnUploadSessionOnAnotherHost() async throws {
        let capture = GeminiRequestCapture()
        GeminiTranscribeMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(
                for: request,
                headers: ["X-Goog-Upload-URL": "https://attacker.test/upload/v1beta/files?upload_id=abc"]
            )
        }
        defer { GeminiTranscribeMockURLProtocol.handlerStore.set(nil) }

        await #expect(throws: SpeechKitError.self) {
            try await Self.relayProvider().transcribe(Self.request())
        }
        #expect(capture.requests.count == 1)
    }

    @Test func rejectsUnsupportedInstructionsBeforeUploading() async throws {
        let capture = GeminiRequestCapture()
        GeminiTranscribeMockURLProtocol.handlerStore.set { request in
            capture.append(request)
            return Self.response(for: request)
        }
        defer { GeminiTranscribeMockURLProtocol.handlerStore.set(nil) }

        let provider = GeminiTranscribeProvider(
            configuration: try GeminiTranscribeProviderConfiguration(access: .testRouter()),
            session: Self.makeSession()
        )
        let audio = try TranscriptionAudio(
            data: Data([0x01]),
            fileName: "recording.wav",
            mimeType: "audio/wav",
            fileExtension: "wav"
        )

        await #expect(throws: SpeechKitError.self) {
            try await provider.transcribe(
                TranscriptionRequest(
                    audio: audio,
                    languageHints: [],
                    customVocabulary: [],
                    instructions: "Translate to Swedish"
                )
            )
        }
        #expect(capture.requests.isEmpty)
    }

    @Test func mapsOnlySupportedLanguageHints() {
        #expect(
            GeminiTranscribeAPI.languageCodes(from: ["sv", "en-GB", "unknown", "SV"])
                == ["sv-SE", "en-GB"]
        )
    }

    private static func relayProvider() throws -> GeminiTranscribeProvider {
        GeminiTranscribeProvider(
            configuration: try GeminiTranscribeProviderConfiguration(
                access: .relay(
                    try SpeechRelay(
                        baseURL: URL(string: "https://gateway.test:8787/speech/gemini")!,
                        bearerToken: "rc1.installation"
                    )
                )
            ),
            session: makeSession()
        )
    }

    private static func request() throws -> TranscriptionRequest {
        TranscriptionRequest(
            audio: try TranscriptionAudio(
                data: Data([0x01, 0x02]),
                fileName: "recording.wav",
                mimeType: "audio/wav",
                fileExtension: "wav"
            ),
            languageHints: [],
            customVocabulary: []
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiTranscribeMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            body
        )
    }
}

private final class GeminiTranscribeMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    static let handlerStore = GeminiTranscribeHandlerStore()

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

private final class GeminiTranscribeHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: GeminiTranscribeMockURLProtocol.Handler?

    func set(_ handler: GeminiTranscribeMockURLProtocol.Handler?) {
        lock.withLock { self.handler = handler }
    }

    func get() -> GeminiTranscribeMockURLProtocol.Handler? {
        lock.withLock { handler }
    }
}

private final class GeminiRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
