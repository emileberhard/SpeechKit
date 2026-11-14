import Foundation
import Synchronization

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

    @concurrent public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let prepared = try prepare(ProgressiveTranscriptionRequest(
            languageHints: request.languageHints,
            customVocabulary: request.customVocabulary,
            instructions: request.instructions
        ))
        let (data, response) = try await upload(request.audio, prepared: prepared, uploadFinished: nil)
        return try decode(data, response: response, warnings: prepared.warnings)
    }

    @concurrent public func transcribeSpeakers(_ request: TranscriptionRequest,
        uploadFinished: (@Sendable (Duration) -> Void)? = nil) async throws -> [SpeakerPhrase] {
        let definition = try AzureSpeechAPI.speakerDefinition(configuration: configuration, request: .init(
            languageHints: request.languageHints, customVocabulary: request.customVocabulary, instructions: request.instructions
        ))
        let prepared = try prepare(definition)
        let (data, response) = try await upload(request.audio, prepared: prepared,
            uploadFinished: uploadFinished)
        guard (200..<300).contains(response.statusCode) else { throw failure(for: response) }
        return try JSONDecoder().decode(AzureSpeechAPI.SpeakerResponse.self, from: data).validatedPhrases()
    }

    private func upload(_ audio: TranscriptionAudio, prepared: (multipart: MultipartFormDataBuilder, boundary: String, warnings: [String]),
                        uploadFinished: (@Sendable (Duration) -> Void)?)
        async throws -> (Data, HTTPURLResponse) {
        let fileExtension = audio.fileExtension.lowercased()
        guard ["wav", "mp3", "flac"].contains(fileExtension),
              audio.data.count <= AzureSpeechAPI.maximumAudioBytes else {
            throw SpeechKitError.invalidRequest("Azure Speech audio must be WAV, MP3, or FLAC smaller than 250 MB")
        }
        var multipart = prepared.multipart
        multipart.addFile(
            name: "audio", fileName: "recording.\(fileExtension)",
            mimeType: fileExtension == "mp3" ? "audio/mpeg" : "audio/\(fileExtension)",
            data: audio.data
        )
        multipart.finalize()
        var urlRequest = try makeRequest(boundary: prepared.boundary)
        let body = multipart.build()
        urlRequest.httpBody = body
        let observer = AzureSpeechUploadObserver(bodyBytes: body.count, transport: configuration.access.transport,
                                                 completed: uploadFinished)
        defer { observer.stop() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: observer)
        } catch {
            throw observer.failure ?? error
        }
        guard let response = response as? HTTPURLResponse else { throw SpeechKitError.invalidResponse }
        return (data, response)
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
            transport: configuration.access.transport,
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
        return try prepare((definition, warnings))
    }

    private func prepare(_ definition: (AzureSpeechAPI.Definition, warnings: [String])) throws -> (
        multipart: MultipartFormDataBuilder, boundary: String, warnings: [String]
    ) {
        let data = try JSONEncoder().encode(definition.0)
        let boundary = UUID().uuidString
        var multipart = MultipartFormDataBuilder(boundary: boundary)
        multipart.addField(name: "definition", value: String(decoding: data, as: UTF8.self))
        return (multipart, boundary, definition.warnings)
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

final class AzureSpeechUploadObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let started = ContinuousClock.now
    private let completed: (@Sendable (Duration) -> Void)?
    private let transport: SpeechRelayTransport?
    private let bodyBytes: Int
    private let stallTimeout: Duration
    private let responseTimeout: Duration
    private let progress = Mutex<SpeechUploadWatchdog?>(nil)

    init(bodyBytes: Int, transport: SpeechRelayTransport?, completed: (@Sendable (Duration) -> Void)?,
         stallTimeout: Duration = .seconds(8), responseTimeout: Duration = .seconds(30)) {
        self.bodyBytes = bodyBytes
        self.transport = transport
        self.completed = completed
        self.stallTimeout = stallTimeout
        self.responseTimeout = responseTimeout
    }

    var failure: (any Error)? { progress.withLock { $0 }?.failure }

    func stop() {
        let watchdog = progress.withLock { progress in
            let watchdog = progress
            progress = nil
            return watchdog
        }
        watchdog?.stop()
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let watchdog = SpeechUploadWatchdog(stallTimeout: stallTimeout, responseTimeout: responseTimeout) { _ in task.cancel() }
        watchdog.offer(bodyBytes)
        watchdog.finishBody()
        progress.withLock { $0 = watchdog }
        watchdog.start()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress.withLock { $0 }?.sent(totalBytesSent)
        if totalBytesSent >= bodyBytes, totalBytesSent - bytesSent < bodyBytes {
            completed?(started.duration(to: .now))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        transport?.answer(challenge) ?? (.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        SpeechUploadMetrics.log(task: task, metrics: metrics, transport: transport)
    }
}
