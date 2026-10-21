import Foundation

public struct GeminiProviderConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let model: String

    public init(access: SpeechProviderAccess, model: String = "gemini-3.5-flash") throws {
        guard !model.isEmpty else {
            throw SpeechKitError.invalidConfiguration("Gemini model is required")
        }

        self.access = access
        self.model = model
    }
}

public final class GeminiTranscriptionProvider: TranscriptionProvider {
    public let id = "gemini"
    public let maximumAudioByteCount = GeminiAPI.maximumInlineAudioBytes

    private let configuration: GeminiProviderConfiguration
    private let session: URLSession

    private var endpoint: URL {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(configuration.model):generateContent")!
    }

    public init(configuration: GeminiProviderConfiguration) {
        self.configuration = configuration
        session = SpeechKitURLSessionFactory.batchSession(for: configuration.access)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let prompt = transcriptionPrompt(for: request)
        let base64Audio = request.audio.data.base64EncodedString()

        let requestBody = GeminiAPI.GenerateContentRequest(
            contents: [
                .init(parts: [
                    .text(prompt),
                    .inlineData(mimeType: request.audio.mimeType, data: base64Audio),
                ])
            ],
            generationConfig: .init(
                thinkingConfig: .init(thinkingLevel: "LOW")
            )
        )

        var urlRequest = try configuration.access.request(upstream: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw configuration.access.failure(httpResponse, body: body)
        }

        let decoded = try JSONDecoder().decode(GeminiAPI.GenerateContentResponse.self, from: data)

        let text = decoded.candidates?
            .first?
            .content?
            .parts?
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionResult(text: text ?? "", providerID: id)
    }

    private func transcriptionPrompt(for request: TranscriptionRequest) -> String {
        var sections: [String] = [
            "Transcribe this speech exactly. Return only the raw transcription text — no commentary, no formatting, no quotes."
        ]

        if let instructions = request.instructions {
            sections.append(instructions)
        }

        if !request.languageHints.isEmpty {
            let joined = request.languageHints.joined(separator: ", ")
            sections.append("Expected languages: \(joined).")
        }

        if !request.customVocabulary.isEmpty {
            let terms = request.customVocabulary.joined(separator: ", ")
            sections.append("Preserve these terms exactly when they appear: \(terms).")
        }

        return sections.joined(separator: " ")
    }
}
