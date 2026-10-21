import Foundation

public struct GeminiRealtimeSessionConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let modelID: String
    public let customVocabulary: [String]
    public let languageHints: [String]
    public let mode: GeminiTranscriptionMode
    public let sampleRate = GeminiTranscribeAPI.sampleRate

    public init(
        access: SpeechProviderAccess,
        modelID: String = "gemini-3.5-transcribe-live",
        customVocabulary: [String] = [],
        languageHints: [String] = [],
        mode: GeminiTranscriptionMode = .verbatim
    ) throws {
        guard !modelID.isEmpty else {
            throw SpeechKitError.invalidConfiguration("Gemini realtime transcription model is required")
        }

        self.access = access
        self.modelID = modelID
        self.customVocabulary = GeminiTranscribeAPI.customVocabulary(from: customVocabulary)
        self.languageHints = languageHints
        self.mode = mode
    }
}

public enum GeminiRealtimeEvent: Sendable {
    case setupComplete
    case partialTranscript(String)
    case committedTranscript(String)
}

public enum GeminiRealtimeSessionError: Error, Sendable {
    case alreadyConnected
    case notConnected
    case invalidMessage(String)
    case server(message: String)
}

extension GeminiRealtimeSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            return "Gemini realtime session is already connected"
        case .notConnected:
            return "Gemini realtime session is not connected"
        case .invalidMessage(let message):
            return "Invalid Gemini realtime message: \(message)"
        case .server(let message):
            return "Gemini realtime error: \(message)"
        }
    }
}

enum GeminiRealtimeAPI {
    struct SetupPayload: Encodable {
        struct Setup: Encodable {
            struct GenerationConfiguration: Encodable {
                let responseModalities = ["TEXT"]
            }

            struct RealtimeInputConfiguration: Encodable {
                struct AutomaticActivityDetection: Encodable {
                    let disabled = true
                }

                let automaticActivityDetection = AutomaticActivityDetection()
            }

            struct AudioTranscriptionConfiguration: Encodable {
                let languageCodes: [String]
                let customVocabulary: [String]
                let mode: String
            }

            let model: String
            let generationConfig = GenerationConfiguration()
            let realtimeInputConfig = RealtimeInputConfiguration()
            let inputAudioTranscription: AudioTranscriptionConfiguration
        }

        let setup: Setup
    }

    struct ActivityStartPayload: Encodable {
        struct ActivityStart: Encodable {}
        struct RealtimeInput: Encodable {
            let activityStart = ActivityStart()
        }

        let realtimeInput = RealtimeInput()
    }

    struct ActivityEndPayload: Encodable {
        struct ActivityEnd: Encodable {}
        struct RealtimeInput: Encodable {
            let activityEnd = ActivityEnd()
        }

        let realtimeInput = RealtimeInput()
    }

    struct AudioPayload: Encodable {
        struct RealtimeInput: Encodable {
            struct Audio: Encodable {
                let data: String
                let mimeType: String
            }

            let audio: Audio
        }

        let realtimeInput: RealtimeInput
    }

    struct ResponseEnvelope: Decodable {
        struct SetupComplete: Decodable {}

        struct ServerContent: Decodable {
            struct Transcription: Decodable {
                let text: String
            }

            let interimInputTranscription: Transcription?
            let inputTranscription: Transcription?
        }

        struct ProviderError: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }

        let setupComplete: SetupComplete?
        let serverContent: ServerContent?
        let error: ProviderError?
    }

    static func setupPayload(
        configuration: GeminiRealtimeSessionConfiguration,
        languageCode: String?
    ) -> SetupPayload {
        let hints = languageCode.map { [$0] } ?? configuration.languageHints
        return SetupPayload(
            setup: .init(
                model: "models/\(configuration.modelID)",
                inputAudioTranscription: .init(
                    languageCodes: GeminiTranscribeAPI.languageCodes(from: hints),
                    customVocabulary: configuration.customVocabulary,
                    mode: configuration.mode.liveValue
                )
            )
        )
    }

    static func audioPayload(_ data: Data, sampleRate: Int) -> AudioPayload {
        AudioPayload(
            realtimeInput: .init(
                audio: .init(
                    data: data.base64EncodedString(),
                    mimeType: "audio/pcm;rate=\(sampleRate)"
                )
            )
        )
    }

    static func decodeEvent(from data: Data) throws -> GeminiRealtimeEvent? {
        let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: data)

        if let error = envelope.error {
            let details = [error.status, error.message, error.code.map(String.init)]
                .compactMap { $0 }
                .joined(separator: ": ")
            throw GeminiRealtimeSessionError.server(message: details.isEmpty ? "Unknown error" : details)
        }

        if envelope.setupComplete != nil {
            return .setupComplete
        }

        if let transcript = envelope.serverContent?.inputTranscription?.text {
            return .committedTranscript(transcript)
        }

        if let transcript = envelope.serverContent?.interimInputTranscription?.text {
            return .partialTranscript(transcript)
        }

        return nil
    }
}
