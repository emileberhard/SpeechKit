import Foundation

public struct ElevenLabsProviderConfiguration: Sendable {
    public let access: SpeechProviderAccess

    public init(access: SpeechProviderAccess) {
        self.access = access
    }
}

public final class ElevenLabsTranscriptionProvider: TranscriptionProvider {
    public let id = "elevenlabs"
    public let maximumAudioByteCount = 3_000_000_000

    private let configuration: ElevenLabsProviderConfiguration
    private let session: URLSession
    private let batchEndpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    public init(
        configuration: ElevenLabsProviderConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.session = session ?? SpeechKitURLSessionFactory.batchSession(for: configuration.access)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let text = try await transcribeBatch(request)
        return TranscriptionResult(text: text, providerID: id)
    }

    private func transcribeBatch(_ request: TranscriptionRequest) async throws -> String {
        let boundary = UUID().uuidString

        var multipart = MultipartFormDataBuilder(boundary: boundary)
        multipart.addFile(
            name: "file",
            fileName: request.audio.fileName,
            mimeType: request.audio.mimeType,
            data: request.audio.data
        )
        multipart.addField(name: "model_id", value: "scribe_v2")

        if let languageCode = singleLanguageCode(from: request.languageHints) {
            multipart.addField(name: "language_code", value: languageCode)
        }

        let keyterms = Self.compatibleKeyterms(from: request.customVocabulary)
        multipart.addArrayField(name: "keyterms", values: keyterms)

        multipart.finalize()

        var urlRequest = try configuration.access.request(upstream: batchEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = multipart.build()

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw configuration.access.failure(httpResponse, body: body)
        }

        let decoded = try JSONDecoder().decode(ElevenLabsAPI.BatchResponse.self, from: data)

        switch decoded {
        case .chunk(let chunk):
            return chunk.text
        case .multichannel(let multichannel):
            return multichannel.transcripts.map(\.text).joined(separator: " ")
        case .webhook(let webhook):
            throw SpeechKitError.providerFailure("Unexpected webhook response: \(webhook.message)")
        }
    }

    private func singleLanguageCode(from hints: [String]) -> String? {
        guard hints.count == 1 else {
            return nil
        }
        return hints[0]
    }

    /// Scribe v2 accepts up to 1,000 keyterms of at most 50 characters and
    /// 5 words each; drop entries the API would reject.
    static func compatibleKeyterms(from vocabulary: [String]) -> [String] {
        Array(
            CustomVocabulary.normalized(vocabulary)
                .filter {
                    $0.count <= 50
                        && $0.split(whereSeparator: { $0.isWhitespace }).count <= 5
                }
                .prefix(1_000)
        )
    }
}
