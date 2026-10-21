import Foundation

public struct AssemblyAIProviderConfiguration: Sendable {
    public static let defaultSpeechModels = ["universal-3-5-pro", "universal-2"]

    public let access: SpeechProviderAccess
    public let pollIntervalSeconds: Double
    public let speechModels: [String]

    public init(
        access: SpeechProviderAccess,
        pollIntervalSeconds: Double,
        speechModels: [String] = Self.defaultSpeechModels
    ) throws {
        guard pollIntervalSeconds > 0 else {
            throw SpeechKitError.invalidConfiguration("pollIntervalSeconds must be > 0")
        }
        guard !speechModels.isEmpty, speechModels.allSatisfy({ !$0.isEmpty }) else {
            throw SpeechKitError.invalidConfiguration("AssemblyAI speech models are required")
        }

        self.access = access
        self.pollIntervalSeconds = pollIntervalSeconds
        self.speechModels = speechModels
    }
}

public final class AssemblyAITranscriptionProvider: TranscriptionProvider {
    public let id = "assemblyai"
    public let maximumAudioByteCount = 2_200_000_000

    private let configuration: AssemblyAIProviderConfiguration
    private let session: URLSession
    private let baseURL = URL(string: "https://api.assemblyai.com/v2")!

    public init(configuration: AssemblyAIProviderConfiguration) {
        self.configuration = configuration
        session = SpeechKitURLSessionFactory.batchSession(for: configuration.access)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let uploadURL = try await uploadAudio(request.audio.data)
        let transcriptID = try await submitTranscription(uploadURL: uploadURL, request: request)
        let text = try await pollForCompletion(transcriptID: transcriptID)
        return TranscriptionResult(text: text, providerID: id)
    }

    /// Universal-3.5 Pro accepts up to 1,000 keyterms of at most 6 words each;
    /// drop entries the API would reject.
    static func compatibleKeyterms(from vocabulary: [String]) -> [String] {
        Array(
            CustomVocabulary.normalized(vocabulary)
                .filter { $0.split(separator: " ").count <= 6 }
                .prefix(1_000)
        )
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        try configuration.access.request(upstream: url)
    }

    private func uploadAudio(_ data: Data) async throws -> String {
        var urlRequest = try authorizedRequest(url: baseURL.appendingPathComponent("upload"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data

        let (responseData, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw configuration.access.failure(httpResponse, body: body)
        }

        let decoded = try JSONDecoder().decode(AssemblyAIAPI.UploadResponse.self, from: responseData)
        return decoded.upload_url
    }

    private func submitTranscription(uploadURL: String, request: TranscriptionRequest) async throws -> String {
        var urlRequest = try authorizedRequest(url: baseURL.appendingPathComponent("transcript"))
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Universal-3.5 Pro first; the explicit universal-2 entry makes the
        // API's routing for languages outside U3.5 Pro's supported set
        // explicit instead of silent. word_boost is intentionally absent:
        // it silently downgrades U3.5 Pro requests to Universal-2.
        let keyterms = Self.compatibleKeyterms(from: request.customVocabulary)
        let singleLanguage = request.languageHints.count == 1 ? request.languageHints[0] : nil
        let body = AssemblyAIAPI.TranscriptRequest(
            audio_url: uploadURL,
            speech_models: configuration.speechModels,
            language_code: singleLanguage,
            language_detection: singleLanguage == nil ? true : nil,
            language_detection_options: singleLanguage == nil && !request.languageHints.isEmpty
                ? .init(expected_languages: request.languageHints)
                : nil,
            keyterms_prompt: keyterms.isEmpty ? nil : keyterms
        )

        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw configuration.access.failure(httpResponse, body: responseBody)
        }

        let decoded = try JSONDecoder().decode(AssemblyAIAPI.TranscriptResponse.self, from: data)
        return decoded.id
    }

    private func pollForCompletion(transcriptID: String) async throws -> String {
        var urlRequest = try authorizedRequest(url: baseURL.appendingPathComponent("transcript/\(transcriptID)"))
        urlRequest.httpMethod = "GET"

        while true {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpeechKitError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                let responseBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw configuration.access.failure(httpResponse, body: responseBody)
            }

            let decoded = try JSONDecoder().decode(AssemblyAIAPI.StatusResponse.self, from: data)

            switch decoded.status {
            case "completed":
                guard let text = decoded.text else {
                    throw SpeechKitError.invalidResponse
                }
                return text

            case "error":
                throw SpeechKitError.providerFailure(decoded.error ?? "AssemblyAI transcription failed")

            default:
                let nanos = UInt64(configuration.pollIntervalSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
            }
        }
    }
}
