import Foundation

public enum ElevenLabsRealtimeCommitStrategy: String, Sendable, Codable {
    case manual
    case vad
}

public struct ElevenLabsRealtimeSessionConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let modelID: String
    public let keyterms: [String]
    /// Ordered ISO 639-1 language codes expected during the session. A single
    /// language is pinned through `language_code`; several languages keep
    /// automatic detection enabled and prime the first audio chunk through
    /// `previous_text`.
    public let languageHints: [String]
    public let sampleRate: Int
    public let includeTimestamps: Bool
    public let commitStrategy: ElevenLabsRealtimeCommitStrategy
    public let vadSilenceThresholdSeconds: Double
    public let vadThreshold: Double
    public let minSpeechDurationMilliseconds: Int
    public let minSilenceDurationMilliseconds: Int
    public let enableLogging: Bool

    public init(
        access: SpeechProviderAccess,
        modelID: String = "scribe_v2_realtime",
        keyterms: [String] = [],
        languageHints: [String] = [],
        sampleRate: Int = 16_000,
        includeTimestamps: Bool = true,
        commitStrategy: ElevenLabsRealtimeCommitStrategy = .vad,
        vadSilenceThresholdSeconds: Double = 3.0,
        vadThreshold: Double = 0.4,
        minSpeechDurationMilliseconds: Int = 100,
        minSilenceDurationMilliseconds: Int = 100,
        enableLogging: Bool = true
    ) throws {
        guard !modelID.isEmpty else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime model is required")
        }
        guard sampleRate > 0 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime sample rate must be > 0")
        }
        guard vadSilenceThresholdSeconds > 0 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime VAD silence threshold must be > 0")
        }
        guard vadThreshold >= 0 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime VAD threshold must be >= 0")
        }
        guard minSpeechDurationMilliseconds >= 0 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime min speech duration must be >= 0")
        }
        guard minSilenceDurationMilliseconds >= 0 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime min silence duration must be >= 0")
        }
        let validatedKeyterms = try Self.validatedKeyterms(keyterms)

        self.access = access
        self.modelID = modelID
        self.keyterms = validatedKeyterms
        self.languageHints = Self.normalizedLanguageHints(languageHints)
        self.sampleRate = sampleRate
        self.includeTimestamps = includeTimestamps
        self.commitStrategy = commitStrategy
        self.vadSilenceThresholdSeconds = vadSilenceThresholdSeconds
        self.vadThreshold = vadThreshold
        self.minSpeechDurationMilliseconds = minSpeechDurationMilliseconds
        self.minSilenceDurationMilliseconds = minSilenceDurationMilliseconds
        self.enableLogging = enableLogging
    }

    public static func compatibleKeyterms(from vocabulary: [String]) -> [String] {
        Array(CustomVocabulary.normalized(vocabulary).filter { $0.count <= 20 }.prefix(50))
    }

    private static func validatedKeyterms(_ keyterms: [String]) throws -> [String] {
        let normalized = CustomVocabulary.normalized(keyterms)

        guard normalized.count <= 50 else {
            throw SpeechKitError.invalidConfiguration("ElevenLabs realtime keyterms exceed 50 items")
        }

        for term in normalized {
            guard term.count <= 20 else {
                throw SpeechKitError.invalidConfiguration("ElevenLabs realtime keyterm exceeds 20 characters")
            }
        }

        return normalized
    }

    private static func normalizedLanguageHints(_ hints: [String]) -> [String] {
        var seen: Set<String> = []
        return hints.compactMap { hint in
            let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let code = Locale.Language(identifier: trimmed).languageCode?.identifier ?? trimmed
            let normalized = code.lowercased()
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }
}

struct ElevenLabsRealtimeLanguageConditioning: Equatable, Sendable {
    let languageCode: String?
    let previousText: String?
}

extension ElevenLabsRealtimeSessionConfiguration {
    func languageConditioning(languageCode override: String? = nil) -> ElevenLabsRealtimeLanguageConditioning {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return ElevenLabsRealtimeLanguageConditioning(languageCode: override, previousText: nil)
        }

        guard languageHints.count > 1 else {
            return ElevenLabsRealtimeLanguageConditioning(
                languageCode: languageHints.first,
                previousText: nil
            )
        }

        return ElevenLabsRealtimeLanguageConditioning(
            languageCode: nil,
            previousText: Self.preferredLanguagesPreviousText(languageHints)
        )
    }

    private static func preferredLanguagesPreviousText(_ languageCodes: [String]) -> String {
        let names = languageCodes.map { code in
            Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
        }

        let namedPrompt = "Vi pratar \(joinedLanguageNames(names))."
        if namedPrompt.count < ElevenLabsRealtimeAPI.previousTextRecommendedLimit {
            return namedPrompt
        }

        let codedPrompt = "Vi pratar \(joinedLanguageNames(languageCodes))."
        if codedPrompt.count < ElevenLabsRealtimeAPI.previousTextRecommendedLimit {
            return codedPrompt
        }

        var compactCodes: [String] = []
        for code in languageCodes {
            let candidate = (compactCodes + [code]).joined(separator: "/")
            guard candidate.count < ElevenLabsRealtimeAPI.previousTextRecommendedLimit else { break }
            compactCodes.append(code)
        }
        return compactCodes.joined(separator: "/")
    }

    private static func joinedLanguageNames(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

public struct ElevenLabsRealtimeTranscriptionWord: Decodable, Sendable {
    public let text: String
    public let start: Double?
    public let end: Double?
    public let type: String?
    public let speakerID: String?
    public let logprob: Double?
    public let characters: [ElevenLabsRealtimeTranscriptionCharacter]?

    enum CodingKeys: String, CodingKey {
        case text
        case start
        case end
        case type
        case speakerID = "speaker_id"
        case logprob
        case characters
    }
}

public struct ElevenLabsRealtimeTranscriptionCharacter: Decodable, Sendable {
    public let text: String
    public let start: Double?
    public let end: Double?

    private enum CodingKeys: String, CodingKey {
        case text
        case character
        case value
        case start
        case end
    }

    public init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let text = try? singleValue.decode(String.self) {
            self.text = text
            self.start = nil
            self.end = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text =
            try container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .character)
            ?? container.decodeIfPresent(String.self, forKey: .value)
            ?? ""
        self.start = try container.decodeIfPresent(Double.self, forKey: .start)
        self.end = try container.decodeIfPresent(Double.self, forKey: .end)
    }
}

public struct ElevenLabsRealtimeSessionStarted: Sendable {
    public let sessionID: String
    public let sampleRate: Int?
    public let audioFormat: String?
    public let languageCode: String?
    public let modelID: String?
    public let commitStrategy: ElevenLabsRealtimeCommitStrategy?
    public let includeTimestamps: Bool?
}

public enum ElevenLabsRealtimeEvent: Sendable {
    case sessionStarted(ElevenLabsRealtimeSessionStarted)
    case partialTranscript(String)
    case finalTranscript(String)
    case finalTranscriptWithTimestamps(
        text: String,
        languageCode: String?,
        words: [ElevenLabsRealtimeTranscriptionWord]?
    )
    case committedTranscript(String)
    case committedTranscriptWithTimestamps(
        text: String,
        languageCode: String?,
        words: [ElevenLabsRealtimeTranscriptionWord]?
    )
}

public enum ElevenLabsRealtimeSessionError: Error, Sendable {
    case alreadyConnected
    case notConnected
    case invalidURL
    case invalidMessage(String)
    case server(messageType: String, message: String)
}

extension ElevenLabsRealtimeSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "ElevenLabs realtime session is already connected"
        case .notConnected:
            return "ElevenLabs realtime session is not connected"
        case .invalidURL:
            return "Invalid ElevenLabs realtime URL"
        case .invalidMessage(let message):
            return "Invalid ElevenLabs realtime message: \(message)"
        case .server(let messageType, let message):
            return "ElevenLabs realtime \(messageType): \(message)"
        }
    }
}

enum ElevenLabsRealtimeAPI {
    static let audioFormat = "pcm_16000"
    static let previousTextRecommendedLimit = 50

    struct Envelope: Decodable {
        let messageType: String

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
        }
    }

    struct InputAudioChunkPayload: Encodable {
        let messageType = "input_audio_chunk"
        let audioBase64: String
        let commit: Bool
        let sampleRate: Int
        let previousText: String?

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case audioBase64 = "audio_base_64"
            case commit
            case sampleRate = "sample_rate"
            case previousText = "previous_text"
        }
    }

    struct SessionStartedPayload: Decodable {
        struct Config: Decodable {
            let sampleRate: Int?
            let audioFormat: String?
            let languageCode: String?
            let commitStrategy: ElevenLabsRealtimeCommitStrategy?
            let modelID: String?
            let includeTimestamps: Bool?

            enum CodingKeys: String, CodingKey {
                case sampleRate = "sample_rate"
                case audioFormat = "audio_format"
                case languageCode = "language_code"
                case commitStrategy = "commit_strategy"
                case modelID = "model_id"
                case includeTimestamps = "include_timestamps"
            }
        }

        let sessionID: String
        let config: Config

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case config
        }
    }

    struct PartialTranscriptPayload: Decodable {
        let text: String
    }

    struct CommittedTranscriptPayload: Decodable {
        let text: String
    }

    struct TranscriptWithTimestampsPayload: Decodable {
        let text: String
        let languageCode: String?
        let words: [ElevenLabsRealtimeTranscriptionWord]?

        enum CodingKeys: String, CodingKey {
            case text
            case languageCode = "language_code"
            case words
        }
    }

    struct ErrorPayload: Decodable {
        let error: String?
        let message: String?
    }

    static func decodeEvent(from data: Data) throws -> ElevenLabsRealtimeEvent {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: data)

        switch envelope.messageType {
        case "session_started":
            let payload = try decoder.decode(SessionStartedPayload.self, from: data)
            return .sessionStarted(
                ElevenLabsRealtimeSessionStarted(
                    sessionID: payload.sessionID,
                    sampleRate: payload.config.sampleRate,
                    audioFormat: payload.config.audioFormat,
                    languageCode: payload.config.languageCode,
                    modelID: payload.config.modelID,
                    commitStrategy: payload.config.commitStrategy,
                    includeTimestamps: payload.config.includeTimestamps
                )
            )
        case "partial_transcript":
            return .partialTranscript(try decoder.decode(PartialTranscriptPayload.self, from: data).text)
        case "final_transcript":
            return .finalTranscript(try decoder.decode(CommittedTranscriptPayload.self, from: data).text)
        case "final_transcript_with_timestamps":
            let payload = try decoder.decode(TranscriptWithTimestampsPayload.self, from: data)
            return .finalTranscriptWithTimestamps(
                text: payload.text,
                languageCode: payload.languageCode,
                words: payload.words
            )
        case "committed_transcript":
            return .committedTranscript(try decoder.decode(CommittedTranscriptPayload.self, from: data).text)
        case "committed_transcript_with_timestamps":
            let payload = try decoder.decode(TranscriptWithTimestampsPayload.self, from: data)
            return .committedTranscriptWithTimestamps(
                text: payload.text,
                languageCode: payload.languageCode,
                words: payload.words
            )
        default:
            let payload = (try? decoder.decode(ErrorPayload.self, from: data))
            let message = payload?.error ?? payload?.message ?? "Unknown error"
            throw ElevenLabsRealtimeSessionError.server(messageType: envelope.messageType, message: message)
        }
    }
}
