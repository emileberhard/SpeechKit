import Foundation

public enum OpenAIRealtimeTranscriptionDelay: String, Sendable, Encodable {
    case minimal
    case low
    case medium
    case high
    case xhigh
}

public enum OpenAIRealtimeNoiseReduction: String, Sendable, Encodable {
    case nearField = "near_field"
    case farField = "far_field"
}

public enum OpenAIRealtimeSemanticVADEagerness: String, Sendable, Encodable {
    case low
    case medium
    case high
    case auto
}

public enum OpenAIRealtimeTurnDetection: Sendable {
    case disabled
    case serverVAD(
        threshold: Double = 0.5,
        prefixPaddingMilliseconds: Int = 300,
        silenceDurationMilliseconds: Int = 500
    )
    case semanticVAD(eagerness: OpenAIRealtimeSemanticVADEagerness)
}

public struct OpenAIRealtimeSessionConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let modelID: String
    public let customVocabulary: [String]
    /// Expected languages (ISO 639-1). The realtime API only accepts a single
    /// `language` per session: one hint pins it unless connect passes an
    /// override, while several expected languages can only travel in the
    /// transcription prompt — and only the gpt-4o transcribe family treats the
    /// prompt as free-form instructions.
    public let languageHints: [String]
    public let sampleRate: Int
    public let turnDetection: OpenAIRealtimeTurnDetection
    public let transcriptionDelay: OpenAIRealtimeTranscriptionDelay?
    public let noiseReduction: OpenAIRealtimeNoiseReduction?

    public var supportsCustomVocabulary: Bool {
        Self.supportsCustomVocabulary(modelID: modelID)
    }

    var supportsFreeTextPrompt: Bool {
        modelID.hasPrefix("gpt-4o-")
    }

    public init(
        access: SpeechProviderAccess,
        modelID: String = "gpt-realtime-whisper",
        customVocabulary: [String] = [],
        languageHints: [String] = [],
        sampleRate: Int = 24_000,
        turnDetection: OpenAIRealtimeTurnDetection = .disabled,
        transcriptionDelay: OpenAIRealtimeTranscriptionDelay? = nil,
        noiseReduction: OpenAIRealtimeNoiseReduction? = nil
    ) throws {
        guard !modelID.isEmpty else {
            throw SpeechKitError.invalidConfiguration("OpenAI realtime transcription model is required")
        }
        guard sampleRate > 0 else {
            throw SpeechKitError.invalidConfiguration("OpenAI realtime sample rate must be > 0")
        }

        switch turnDetection {
        case .disabled, .semanticVAD:
            break
        case .serverVAD(let threshold, let prefixPaddingMilliseconds, let silenceDurationMilliseconds):
            guard (0 ... 1).contains(threshold) else {
                throw SpeechKitError.invalidConfiguration("OpenAI realtime VAD threshold must be between 0 and 1")
            }
            guard prefixPaddingMilliseconds >= 0 else {
                throw SpeechKitError.invalidConfiguration("OpenAI realtime prefix padding must be >= 0")
            }
            guard silenceDurationMilliseconds >= 0 else {
                throw SpeechKitError.invalidConfiguration("OpenAI realtime silence duration must be >= 0")
            }
        }

        let isRealtimeWhisper = modelID.hasPrefix("gpt-realtime-whisper")
        if isRealtimeWhisper {
            guard case .disabled = turnDetection else {
                throw SpeechKitError.invalidConfiguration(
                    "gpt-realtime-whisper requires OpenAI turn detection to be disabled"
                )
            }
        } else if transcriptionDelay != nil {
            throw SpeechKitError.invalidConfiguration(
                "OpenAI realtime transcription delay is only supported by gpt-realtime-whisper"
            )
        }

        self.access = access
        self.modelID = modelID
        self.customVocabulary = CustomVocabulary.normalized(customVocabulary)
        self.languageHints = languageHints
        self.sampleRate = sampleRate
        self.turnDetection = turnDetection
        self.transcriptionDelay = transcriptionDelay
        self.noiseReduction = noiseReduction
    }

    public static func supportsCustomVocabulary(modelID: String) -> Bool {
        !modelID.hasPrefix("gpt-realtime-whisper")
    }
}

public struct OpenAIRealtimeSessionInfo: Sendable {
    public let sessionID: String?
    public let sessionType: String?
    public let modelID: String?
}

public enum OpenAIRealtimeEvent: Sendable {
    case sessionUpdated(OpenAIRealtimeSessionInfo)
    case speechStarted(itemID: String)
    case speechStopped(itemID: String)
    case audioCommitted(itemID: String)
    case commitRejected(message: String)
    case partialTranscript(itemID: String, delta: String)
    case committedTranscript(itemID: String, transcript: String)
}

public enum OpenAIRealtimeSessionError: Error, Sendable {
    case alreadyConnected
    case notConnected
    case invalidURL
    case invalidMessage(String)
    case server(message: String)
}

extension OpenAIRealtimeSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "OpenAI realtime session is already connected"
        case .notConnected:
            return "OpenAI realtime session is not connected"
        case .invalidURL:
            return "Invalid OpenAI realtime URL"
        case .invalidMessage(let message):
            return "Invalid OpenAI realtime message: \(message)"
        case .server(let message):
            return "OpenAI realtime error: \(message)"
        }
    }
}

enum OpenAIRealtimeAPI {
    static let websocketIntent = "transcription"

    struct SessionUpdatePayload: Encodable {
        let type = "session.update"
        let session: TranscriptionSession
    }

    struct TranscriptionSession: Encodable {
        let type = "transcription"
        let audio: Audio
    }

    struct Audio: Encodable {
        let input: AudioInput
    }

    struct AudioInput: Encodable {
        let format: AudioFormat
        let noiseReduction: NoiseReduction?
        let transcription: AudioTranscription
        let turnDetection: TurnDetection?

        enum CodingKeys: String, CodingKey {
            case format
            case noiseReduction = "noise_reduction"
            case transcription
            case turnDetection = "turn_detection"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(format, forKey: .format)
            try container.encodeIfPresent(noiseReduction, forKey: .noiseReduction)
            try container.encode(transcription, forKey: .transcription)

            if let turnDetection {
                try container.encode(turnDetection, forKey: .turnDetection)
            } else {
                try container.encodeNil(forKey: .turnDetection)
            }
        }
    }

    struct AudioFormat: Encodable {
        let type = "audio/pcm"
        let rate: Int
    }

    struct AudioTranscription: Encodable {
        let model: String
        let language: String?
        let prompt: String?
        let delay: OpenAIRealtimeTranscriptionDelay?
    }

    struct NoiseReduction: Encodable {
        let type: OpenAIRealtimeNoiseReduction
    }

    struct TurnDetection: Encodable {
        let type: String
        let threshold: Double?
        let prefixPaddingMilliseconds: Int?
        let silenceDurationMilliseconds: Int?
        let eagerness: OpenAIRealtimeSemanticVADEagerness?

        enum CodingKeys: String, CodingKey {
            case type
            case threshold
            case prefixPaddingMilliseconds = "prefix_padding_ms"
            case silenceDurationMilliseconds = "silence_duration_ms"
            case eagerness
        }
    }

    struct AppendAudioPayload: Encodable {
        let type = "input_audio_buffer.append"
        let audio: String
    }

    static let commitEventID = "speechkit_commit"

    struct CommitAudioPayload: Encodable {
        let type = "input_audio_buffer.commit"
        let eventID = OpenAIRealtimeAPI.commitEventID

        enum CodingKeys: String, CodingKey {
            case type
            case eventID = "event_id"
        }
    }

    struct ItemPayload: Decodable {
        let itemID: String

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
        }
    }

    struct Envelope: Decodable {
        let type: String
    }

    struct SessionUpdatedPayload: Decodable {
        let session: SessionPayload?
    }

    struct SessionPayload: Decodable {
        let id: String?
        let type: String?
        let model: String?
    }

    struct TranscriptionDeltaPayload: Decodable {
        let itemID: String
        let delta: String

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case delta
        }
    }

    struct TranscriptionCompletedPayload: Decodable {
        let itemID: String
        let transcript: String

        enum CodingKeys: String, CodingKey {
            case itemID = "item_id"
            case transcript
        }
    }

    struct ErrorPayload: Decodable {
        struct ErrorBody: Decodable {
            let message: String?
            let code: String?
            let type: String?
            let eventID: String?

            enum CodingKeys: String, CodingKey {
                case message
                case code
                case type
                case eventID = "event_id"
            }
        }

        let error: ErrorBody
    }

    static func sessionUpdatePayload(
        configuration: OpenAIRealtimeSessionConfiguration,
        languageCode: String?
    ) -> SessionUpdatePayload {
        var promptSections: [String] = []
        var promptLength = 0
        func appendPromptSection(title: String, values: [String], separator: String) {
            let sectionSeparator = promptSections.isEmpty ? 0 : 2
            var section = title
            var hasValue = false
            for value in values {
                let addition = (hasValue ? separator : "") + value
                guard promptLength + sectionSeparator + section.unicodeScalars.count + addition.unicodeScalars.count <= 1_024 else { continue }
                section += addition
                hasValue = true
            }
            guard hasValue else { return }
            promptSections.append(section)
            promptLength += sectionSeparator + section.unicodeScalars.count
        }

        let pinnedLanguage: String? = if let languageCode, !languageCode.isEmpty {
            languageCode
        } else if configuration.languageHints.count == 1 {
            configuration.languageHints[0]
        } else {
            nil
        }

        if pinnedLanguage == nil,
           configuration.languageHints.count > 1,
           configuration.supportsFreeTextPrompt {
            appendPromptSection(title: "# Expected Languages\n", values: configuration.languageHints, separator: ", ")
        }

        if configuration.supportsCustomVocabulary {
            appendPromptSection(title: "# Dictionary / Common Words\n- ", values: configuration.customVocabulary, separator: "\n- ")
        }

        let prompt = promptSections.isEmpty ? nil : promptSections.joined(separator: "\n\n")

        return SessionUpdatePayload(
            session: TranscriptionSession(
                audio: Audio(
                    input: AudioInput(
                        format: AudioFormat(rate: configuration.sampleRate),
                        noiseReduction: configuration.noiseReduction.map(NoiseReduction.init(type:)),
                        transcription: AudioTranscription(
                            model: configuration.modelID,
                            language: pinnedLanguage,
                            prompt: prompt,
                            delay: configuration.transcriptionDelay
                        ),
                        turnDetection: turnDetectionPayload(configuration.turnDetection)
                    )
                )
            )
        )
    }

    private static func turnDetectionPayload(_ configuration: OpenAIRealtimeTurnDetection) -> TurnDetection? {
        switch configuration {
        case .disabled:
            nil
        case .serverVAD(let threshold, let prefixPaddingMilliseconds, let silenceDurationMilliseconds):
            TurnDetection(
                type: "server_vad",
                threshold: threshold,
                prefixPaddingMilliseconds: prefixPaddingMilliseconds,
                silenceDurationMilliseconds: silenceDurationMilliseconds,
                eagerness: nil
            )
        case .semanticVAD(let eagerness):
            TurnDetection(
                type: "semantic_vad",
                threshold: nil,
                prefixPaddingMilliseconds: nil,
                silenceDurationMilliseconds: nil,
                eagerness: eagerness
            )
        }
    }

    static func decodeEvent(from data: Data) throws -> OpenAIRealtimeEvent? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)

        switch envelope.type {
        case "session.updated", "transcription_session.updated":
            let payload = try JSONDecoder().decode(SessionUpdatedPayload.self, from: data)
            let session = payload.session
            return .sessionUpdated(
                OpenAIRealtimeSessionInfo(
                    sessionID: session?.id,
                    sessionType: session?.type,
                    modelID: session?.model
                )
            )
        case "input_audio_buffer.speech_started":
            return .speechStarted(itemID: try JSONDecoder().decode(ItemPayload.self, from: data).itemID)
        case "input_audio_buffer.speech_stopped":
            return .speechStopped(itemID: try JSONDecoder().decode(ItemPayload.self, from: data).itemID)
        case "input_audio_buffer.committed":
            return .audioCommitted(itemID: try JSONDecoder().decode(ItemPayload.self, from: data).itemID)
        case "conversation.item.input_audio_transcription.delta":
            let payload = try JSONDecoder().decode(TranscriptionDeltaPayload.self, from: data)
            return .partialTranscript(itemID: payload.itemID, delta: payload.delta)
        case "conversation.item.input_audio_transcription.completed":
            let payload = try JSONDecoder().decode(TranscriptionCompletedPayload.self, from: data)
            return .committedTranscript(itemID: payload.itemID, transcript: payload.transcript)
        case "error":
            let payload = try JSONDecoder().decode(ErrorPayload.self, from: data)
            let details = [payload.error.message, payload.error.type, payload.error.code]
                .compactMap { $0 }
                .joined(separator: " ")
            let message = details.isEmpty ? "Unknown error" : details
            guard payload.error.eventID == commitEventID else {
                throw OpenAIRealtimeSessionError.server(message: message)
            }
            return .commitRejected(message: message)
        default:
            return nil
        }
    }
}
