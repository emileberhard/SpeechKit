import Foundation

public struct AzureSpeechTranscriptionProvider: ProgressiveTranscriptionProvider {
    public let id = "azure-speech"
    public var maximumAudioByteCount: Int { AzureSpeechAPI.maximumAudioBytes }
    public var progressiveSampleRate: Int { AzureSpeechAPI.sampleRate }
    private let configuration: AzureSpeechProviderConfiguration
    private let session: URLSession

    public init(configuration: AzureSpeechProviderConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? SpeechKitURLSessionFactory.batchSession(for: configuration.access)
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let options = ProgressiveTranscriptionRequest(
            languageHints: request.languageHints,
            customVocabulary: request.customVocabulary,
            instructions: request.instructions
        )
        let fileExtension = request.audio.fileExtension.lowercased()
        guard ["wav", "mp3", "flac"].contains(fileExtension),
              request.audio.data.count <= AzureSpeechAPI.maximumAudioBytes else {
            throw SpeechKitError.invalidRequest("Azure Speech audio must be WAV, MP3, or FLAC smaller than 250 MB")
        }
        let prepared = try prepare(options)
        var multipart = prepared.multipart
        multipart.addFile(
            name: "audio", fileName: "recording.\(fileExtension)",
            mimeType: fileExtension == "mp3" ? "audio/mpeg" : "audio/\(fileExtension)",
            data: request.audio.data
        )
        multipart.finalize()
        var urlRequest = try makeRequest(boundary: prepared.boundary)
        urlRequest.httpBody = multipart.build()
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else { throw SpeechKitError.invalidResponse }
        return try decode(data, response: response, warnings: prepared.warnings)
    }

    public func startProgressiveTranscription(
        _ request: ProgressiveTranscriptionRequest
    ) async throws -> ProgressiveTranscriptionSession {
        let prepared = try prepare(request)
        var framing = prepared.multipart.streamingFile(name: "audio", fileName: "recording.wav", mimeType: "audio/wav")
        framing.prefix.append(try PCM16WAVFile.streamingHeader(sampleRate: AzureSpeechAPI.sampleRate))
        let urlRequest = try makeRequest(boundary: prepared.boundary)
        try Task.checkCancellation()
        return try ProgressiveTranscriptionSession(
            sampleRate: AzureSpeechAPI.sampleRate,
            maximumAudioBytes: AzureSpeechAPI.maximumAudioBytes - 44,
            request: urlRequest,
            bodyPrefix: framing.prefix,
            bodySuffix: framing.suffix,
            sessionConfiguration: session.configuration,
            transport: configuration.access.relay?.transport,
            failure: { failure(for: $0) },
            decode: { data, response in
                try decode(data, response: response, warnings: prepared.warnings)
            }
        )
    }

    private func prepare(_ request: ProgressiveTranscriptionRequest) throws -> (
        multipart: MultipartFormDataBuilder, boundary: String, warnings: [String]
    ) {
        let (definition, warnings) = try AzureSpeechAPI.definition(configuration: configuration, request: request)
        let data = try JSONEncoder().encode(definition)
        let boundary = UUID().uuidString
        var multipart = MultipartFormDataBuilder(boundary: boundary)
        multipart.addField(name: "definition", value: String(decoding: data, as: UTF8.self))
        return (multipart, boundary, warnings)
    }

    private func makeRequest(boundary: String) throws -> URLRequest {
        var query = URLComponents()
        query.queryItems = [.init(name: "api-version", value: configuration.apiVersion)]
        var request = try configuration.access.azureSpeechRelay().request(
            percentEncodedPath: AzureSpeechAPI.transcribePath,
            percentEncodedQuery: query.percentEncodedQuery,
            webSocket: false
        )
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func failure(for response: HTTPURLResponse) -> SpeechKitError {
        // Service messages can contain request text; keep diagnostics content-free.
        configuration.access.relay?.rejection(in: response) ?? .httpFailure(
            statusCode: response.statusCode,
            body: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        )
    }

    private func decode(_ data: Data, response: HTTPURLResponse, warnings: [String]) throws -> TranscriptionResult {
        guard (200..<300).contains(response.statusCode) else {
            throw failure(for: response)
        }
        let decoded = try JSONDecoder().decode(AzureSpeechAPI.TranscriptionResponse.self, from: data)
        return TranscriptionResult(
            text: decoded.combinedPhrases.map(\.text).joined(separator: "\n"),
            providerID: id,
            modelID: configuration.model.modelID,
            warnings: warnings
        )
    }
}
