import Foundation

/// Opt-in capability for providers that accept audio before its final length is
/// known. Audio input is PCM16 little-endian mono; output is one final result.
public protocol ProgressiveTranscriptionProvider: TranscriptionProvider {
    var progressiveSampleRate: Int { get }
    func startProgressiveTranscription(
        _ request: ProgressiveTranscriptionRequest
    ) async throws -> ProgressiveTranscriptionSession
}

public struct ProgressiveTranscriptionRequest: Sendable {
    public let languageHints: [String]
    public let customVocabulary: [String]
    public let instructions: String?

    public init(
        languageHints: [String] = [],
        customVocabulary: [String] = [],
        instructions: String? = nil
    ) {
        self.languageHints = languageHints
        self.customVocabulary = customVocabulary
        self.instructions = instructions
    }
}

/// Call appendAudio in capture order, then finish once. Network buffering is
/// bounded by the audio spanning the session configuration's request timeout,
/// so a stalled connection outlasts it no longer than URLSession would; overflow
/// fails the whole request without dropping audio. Keep a separate recovery
/// recording if the application supports retries.
public actor ProgressiveTranscriptionSession {
    private enum Phase { case acceptingAudio, finishing, finished, cancelled }
    public nonisolated let sampleRate: Int
    private let upload: StreamingHTTPUpload
    private let maximumAudioBytes: Int
    private let decode: @Sendable (Data, HTTPURLResponse) throws -> TranscriptionResult
    private var audioBytes = 0
    private var phase = Phase.acceptingAudio

    /// Provider adapters supply their HTTP framing, the error for an unsuccessful
    /// response, and the final-response decoder.
    /// The shared transport owns ordering, buffering, cancellation, and EOF.
    public init(
        sampleRate: Int,
        maximumAudioBytes: Int,
        request: URLRequest,
        bodyPrefix: Data,
        bodySuffix: Data,
        sessionConfiguration: URLSessionConfiguration,
        transport: SpeechRelayTransport?,
        failure: @escaping @Sendable (HTTPURLResponse) -> any Error,
        decode: @escaping @Sendable (Data, HTTPURLResponse) throws -> TranscriptionResult
    ) throws {
        guard sampleRate > 0, maximumAudioBytes > 0 else {
            throw SpeechKitError.invalidConfiguration("Progressive audio limits must be positive")
        }
        self.sampleRate = sampleRate
        self.maximumAudioBytes = maximumAudioBytes
        let stalledAudioBytes = Int(sessionConfiguration.timeoutIntervalForRequest.rounded(.up))
            * sampleRate * MemoryLayout<Int16>.size
        self.upload = try StreamingHTTPUpload(
            request: request, prefix: bodyPrefix, suffix: bodySuffix,
            configuration: sessionConfiguration, transport: transport, failure: failure,
            bufferCapacity: bodyPrefix.count + stalledAudioBytes + bodySuffix.count
        )
        self.decode = decode
        self.upload.start()
    }

    deinit { upload.cancel() }

    public func appendAudio(_ pcmData: Data) throws {
        guard phase != .cancelled else { throw CancellationError() }
        guard phase == .acceptingAudio else { throw ProgressiveTranscriptionError.alreadyFinished }
        guard pcmData.count.isMultiple(of: 2), pcmData.count <= maximumAudioBytes - audioBytes else {
            cancel()
            throw SpeechKitError.invalidRequest("PCM data must contain complete samples within the provider size limit")
        }
        do {
            try Task.checkCancellation()
            try upload.append(pcmData)
            audioBytes += pcmData.count
        } catch {
            cancel()
            throw error
        }
    }

    public func finish() async throws -> TranscriptionResult {
        guard phase != .cancelled else { throw CancellationError() }
        guard phase == .acceptingAudio else { throw ProgressiveTranscriptionError.alreadyFinished }
        phase = .finishing
        defer {
            if phase != .cancelled { phase = .finished }
            upload.cancel()
        }
        try Task.checkCancellation()
        guard audioBytes > 0 else { throw SpeechKitError.invalidRequest("PCM audio is empty") }
        try upload.finish()
        let response = try await upload.response()
        try Task.checkCancellation()
        guard phase != .cancelled else { throw CancellationError() }
        return try decode(response.data, response.response)
    }

    public func cancel() {
        phase = .cancelled
        upload.cancel()
    }
}

public enum ProgressiveTranscriptionError: Error, Sendable, Equatable {
    case alreadyFinished
    case bufferOverflow
    case bodyStreamFailed
    case bodyCannotBeReplayed
    case responseTooLarge
    case incompleteUpload
}

extension ProgressiveTranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyFinished: "This transcription upload has already finished"
        case .bufferOverflow: "The network could not keep up with the audio upload"
        case .bodyStreamFailed: "The audio upload stream failed"
        case .bodyCannotBeReplayed: "The server requested a redirect or replay of a live audio upload"
        case .responseTooLarge: "The transcription response exceeded the size limit"
        case .incompleteUpload: "The server completed transcription before the audio upload finished"
        }
    }
}
