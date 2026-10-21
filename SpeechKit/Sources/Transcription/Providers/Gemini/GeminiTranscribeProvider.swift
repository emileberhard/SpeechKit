import Foundation

public struct GeminiTranscribeProviderConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let modelID: String
    public let mode: GeminiTranscriptionMode

    public init(
        access: SpeechProviderAccess,
        modelID: String = "gemini-3.5-transcribe",
        mode: GeminiTranscriptionMode = .verbatim
    ) throws {
        guard !modelID.isEmpty else {
            throw SpeechKitError.invalidConfiguration("Gemini transcription model is required")
        }

        self.access = access
        self.modelID = modelID
        self.mode = mode
    }
}

public final class GeminiTranscribeProvider: TranscriptionProvider {
    public let id = "gemini-transcribe"
    public let maximumAudioByteCount = 2_000_000_000

    private let configuration: GeminiTranscribeProviderConfiguration
    private let session: URLSession
    private let endpoints: Endpoints

    public init(configuration: GeminiTranscribeProviderConfiguration) {
        self.configuration = configuration
        self.session = SpeechKitURLSessionFactory.batchSession(for: configuration.access)
        self.endpoints = .production
    }

    init(configuration: GeminiTranscribeProviderConfiguration, session: URLSession) {
        self.configuration = configuration
        self.session = session
        self.endpoints = .production
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            throw SpeechKitError.invalidRequest("Gemini Transcribe does not support custom instructions")
        }

        let file = try await upload(request.audio)
        defer { try? await deleteFile(named: file.name) }

        let transcript = try await createInteraction(fileURI: file.uri, request: request)
        return TranscriptionResult(text: transcript, providerID: id)
    }
}

extension GeminiTranscribeProvider {
    struct Endpoints: Sendable {
        let upload: URL
        let interactions: URL
        let files: URL

        static let production = Endpoints(
            upload: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!,
            interactions: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
            files: URL(string: "https://generativelanguage.googleapis.com/v1beta/files/")!
        )
    }

    private func upload(_ audio: TranscriptionAudio) async throws -> GeminiTranscribeAPI.UploadResponse.File {
        var startRequest = try authenticatedRequest(url: endpoints.upload)
        startRequest.httpMethod = "POST"
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue(String(audio.data.count), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(audio.mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = try JSONEncoder().encode(
            GeminiTranscribeAPI.UploadStartRequest(
                file: .init(displayName: audio.fileName)
            )
        )

        let (_, startResponse) = try await perform(startRequest)
        var uploadRequest = try authenticatedRequest(url: try resumableUploadURL(from: startResponse))
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(String(audio.data.count), forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        uploadRequest.httpBody = audio.data

        let (data, _) = try await perform(uploadRequest)
        return try JSONDecoder().decode(GeminiTranscribeAPI.UploadResponse.self, from: data).file
    }

    private func createInteraction(
        fileURI: String,
        request: TranscriptionRequest
    ) async throws -> String {
        let urlRequest = try makeInteractionRequest(fileURI: fileURI, request: request)
        let (data, _) = try await perform(urlRequest)
        let response = try JSONDecoder().decode(GeminiTranscribeAPI.InteractionResponse.self, from: data)
        guard let transcript = response.transcript else {
            throw SpeechKitError.invalidResponse
        }
        return transcript
    }

    func makeInteractionRequest(
        fileURI: String,
        request: TranscriptionRequest
    ) throws -> URLRequest {
        let body = GeminiTranscribeAPI.InteractionRequest(
            model: configuration.modelID,
            input: [.init(uri: fileURI, mimeType: request.audio.mimeType)],
            generationConfig: .init(
                transcriptionConfig: .init(
                    languageCodes: GeminiTranscribeAPI.languageCodes(from: request.languageHints),
                    customVocabulary: GeminiTranscribeAPI.customVocabulary(from: request.customVocabulary),
                    mode: .init(type: configuration.mode.rawValue)
                )
            )
        )

        var urlRequest = try authenticatedRequest(url: endpoints.interactions)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func deleteFile(named name: String) async throws {
        guard let fileID = name.split(separator: "/").last, !fileID.isEmpty else {
            throw SpeechKitError.invalidResponse
        }

        var request = try authenticatedRequest(url: endpoints.files.appending(path: String(fileID)))
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    private func resumableUploadURL(from response: HTTPURLResponse) throws -> URL {
        guard let value = response.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let url = URL(string: value),
              url.scheme == endpoints.upload.scheme,
              url.host == endpoints.upload.host else {
            throw SpeechKitError.invalidResponse
        }
        return url
    }

    private func authenticatedRequest(url: URL) throws -> URLRequest {
        try configuration.access.request(upstream: url)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechKitError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data.prefix(64 * 1_024), encoding: .utf8) ?? "Unknown error"
            throw configuration.access.failure(httpResponse, body: body)
        }
        return (data, httpResponse)
    }
}
