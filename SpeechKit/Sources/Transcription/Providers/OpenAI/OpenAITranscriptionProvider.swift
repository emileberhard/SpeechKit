import Foundation

public struct OpenAIProviderConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let model: String

    public init(access: SpeechProviderAccess, model: String) throws {
        guard !model.isEmpty else {
            throw SpeechKitError.invalidConfiguration("OpenAI model is required")
        }

        self.access = access
        self.model = model
    }
}

public final class OpenAITranscriptionProvider: TranscriptionProvider {
    public let id = "openai"
    public let maximumAudioByteCount = 25_000_000

    private let configuration: OpenAIProviderConfiguration
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    public init(
        configuration: OpenAIProviderConfiguration,
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.session = session ?? SpeechKitURLSessionFactory.batchSession(for: configuration.access)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let boundary = UUID().uuidString

        var multipart = MultipartFormDataBuilder(boundary: boundary)
        multipart.addFile(
            name: "file",
            fileName: request.audio.fileName,
            mimeType: request.audio.mimeType,
            data: request.audio.data
        )
        multipart.addField(name: "model", value: configuration.model)

        // A single pinned language goes in the dedicated ISO-639-1 field,
        // which OpenAI documents as improving both accuracy and latency;
        // multiple expected languages can only be hinted through the prompt.
        if request.languageHints.count == 1 {
            multipart.addField(name: "language", value: request.languageHints[0])
        }

        if let prompt = transcriptionPrompt(for: request) {
            multipart.addField(name: "prompt", value: prompt)
        }

        multipart.finalize()

        var urlRequest = try configuration.access.request(upstream: endpoint)
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

        let decoded = try JSONDecoder().decode(OpenAIAPI.TranscriptionResponse.self, from: data)
        return TranscriptionResult(text: decoded.text, providerID: id)
    }

    private func transcriptionPrompt(for request: TranscriptionRequest) -> String? {
        var sections: [String] = []

        if let instructions = request.instructions {
            sections.append("# Instructions & Context\n\(instructions)")
        }

        if request.languageHints.count > 1 {
            let joined = request.languageHints.joined(separator: ", ")
            sections.append("# Expected Languages\n\(joined)")
        }

        if let vocabularyPrompt = CustomVocabulary.promptSection(from: request.customVocabulary) {
            sections.append(vocabularyPrompt)
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
