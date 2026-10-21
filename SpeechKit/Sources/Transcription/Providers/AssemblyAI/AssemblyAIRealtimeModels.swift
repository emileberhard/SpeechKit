import Foundation

public enum AssemblyAIRealtimeMode: String, Sendable, Codable {
    case minimumLatency = "min_latency"
    case balanced
    case maximumAccuracy = "max_accuracy"
}

public struct AssemblyAIRealtimeSessionConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let modelID: String
    public let keyterms: [String]
    public let languageHints: [String]
    public let prompt: String?
    public let mode: AssemblyAIRealtimeMode
    public let sampleRate: Int

    public init(
        access: SpeechProviderAccess,
        modelID: String = "universal-3-5-pro",
        keyterms: [String] = [],
        languageHints: [String] = [],
        prompt: String? = nil,
        mode: AssemblyAIRealtimeMode = .balanced,
        sampleRate: Int = 16_000
    ) throws {
        guard !modelID.isEmpty else {
            throw SpeechKitError.invalidConfiguration("AssemblyAI realtime model is required")
        }
        guard sampleRate > 0 else {
            throw SpeechKitError.invalidConfiguration("AssemblyAI realtime sample rate must be > 0")
        }

        self.access = access
        self.modelID = modelID
        self.keyterms = try Self.validatedKeyterms(keyterms)
        self.languageHints = Self.normalizedLanguageHints(languageHints)
        self.prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.mode = mode
        self.sampleRate = sampleRate
    }

    public static func compatibleKeyterms(from vocabulary: [String]) -> [String] {
        Array(CustomVocabulary.normalized(vocabulary).filter { $0.count <= 50 }.prefix(100))
    }

    private static func validatedKeyterms(_ keyterms: [String]) throws -> [String] {
        let normalized = CustomVocabulary.normalized(keyterms)
        guard normalized.count <= 100 else {
            throw SpeechKitError.invalidConfiguration("AssemblyAI realtime keyterms exceed 100 items")
        }
        guard normalized.allSatisfy({ $0.count <= 50 }) else {
            throw SpeechKitError.invalidConfiguration("AssemblyAI realtime keyterm exceeds 50 characters")
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

public struct AssemblyAIRealtimeSessionInfo: Sendable {
    public let sessionID: String
    public let expiresAt: Int
    public let appliedModelID: String?
}

public struct AssemblyAIRealtimeTermination: Sendable {
    public let audioDurationSeconds: Double
    public let sessionDurationSeconds: Double
}

public enum AssemblyAIRealtimeEvent: Sendable {
    case sessionStarted(AssemblyAIRealtimeSessionInfo)
    case speechStarted(timestampMilliseconds: Int)
    case partialTranscript(turnOrder: Int, text: String)
    case committedTranscript(turnOrder: Int, text: String)
    case sessionTerminated(AssemblyAIRealtimeTermination)
}

public enum AssemblyAIRealtimeSessionError: Error, Sendable {
    case alreadyConnected
    case alreadyCommitted
    case notConnected
    case invalidURL
    case invalidMessage(String)
    case server(code: Int?, message: String)
}

extension AssemblyAIRealtimeSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "AssemblyAI realtime session is already connected"
        case .alreadyCommitted:
            return "AssemblyAI realtime session already ended with its final commit"
        case .notConnected:
            return "AssemblyAI realtime session is not connected"
        case .invalidURL:
            return "Invalid AssemblyAI realtime URL"
        case .invalidMessage(let message):
            return "Invalid AssemblyAI realtime message: \(message)"
        case .server(let code, let message):
            let codeDescription = code.map { " (\($0))" } ?? ""
            return "AssemblyAI realtime error\(codeDescription): \(message)"
        }
    }
}

enum AssemblyAIRealtimeAPI {
    struct ClientMessage: Encodable {
        let type: String
    }

    struct ResponseEnvelope: Decodable {
        struct Configuration: Decodable {
            let model: String?
        }

        let type: String
        let id: String?
        let expiresAt: Int?
        let configuration: Configuration?
        let timestamp: Int?
        let turnOrder: Int?
        let endOfTurn: Bool?
        let transcript: String?
        let audioDurationSeconds: Double?
        let sessionDurationSeconds: Double?
        let errorCode: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case id
            case expiresAt = "expires_at"
            case configuration
            case timestamp
            case turnOrder = "turn_order"
            case endOfTurn = "end_of_turn"
            case transcript
            case audioDurationSeconds = "audio_duration_seconds"
            case sessionDurationSeconds = "session_duration_seconds"
            case errorCode = "error_code"
            case error
        }
    }

    static let forceEndpoint = ClientMessage(type: "ForceEndpoint")
    static let terminate = ClientMessage(type: "Terminate")

    static func decodeEvent(from data: Data) throws -> AssemblyAIRealtimeEvent? {
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)

        switch envelope.type {
        case "Begin":
            guard let id = envelope.id, let expiresAt = envelope.expiresAt else {
                throw AssemblyAIRealtimeSessionError.invalidMessage("Begin omitted session metadata")
            }
            return .sessionStarted(
                .init(
                    sessionID: id,
                    expiresAt: expiresAt,
                    appliedModelID: envelope.configuration?.model
                )
            )

        case "SpeechStarted":
            guard let timestamp = envelope.timestamp else {
                throw AssemblyAIRealtimeSessionError.invalidMessage("SpeechStarted omitted timestamp")
            }
            return .speechStarted(timestampMilliseconds: timestamp)

        case "Turn":
            guard let turnOrder = envelope.turnOrder,
                  let endOfTurn = envelope.endOfTurn,
                  let transcript = envelope.transcript else {
                throw AssemblyAIRealtimeSessionError.invalidMessage("Turn omitted required fields")
            }
            return endOfTurn
                ? .committedTranscript(turnOrder: turnOrder, text: transcript)
                : .partialTranscript(turnOrder: turnOrder, text: transcript)

        case "Termination":
            guard let audioDuration = envelope.audioDurationSeconds,
                  let sessionDuration = envelope.sessionDurationSeconds else {
                throw AssemblyAIRealtimeSessionError.invalidMessage("Termination omitted duration metadata")
            }
            return .sessionTerminated(
                .init(
                    audioDurationSeconds: audioDuration,
                    sessionDurationSeconds: sessionDuration
                )
            )

        case "Error":
            throw AssemblyAIRealtimeSessionError.server(
                code: envelope.errorCode,
                message: envelope.error ?? "Unknown error"
            )

        default:
            return nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
