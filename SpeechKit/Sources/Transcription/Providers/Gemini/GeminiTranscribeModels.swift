import Foundation

public enum GeminiTranscriptionMode: String, Sendable {
    case verbatim
    case smart

    var liveValue: String { rawValue.uppercased() }
}

enum GeminiTranscribeAPI {
    static let sampleRate = 16_000

    struct UploadStartRequest: Encodable {
        struct FileMetadata: Encodable {
            let displayName: String

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }

        let file: FileMetadata
    }

    struct UploadResponse: Decodable {
        struct File: Decodable {
            let name: String
            let uri: String
        }

        let file: File
    }

    struct InteractionRequest: Encodable {
        struct AudioInput: Encodable {
            let type = "audio"
            let uri: String
            let mimeType: String

            enum CodingKeys: String, CodingKey {
                case type
                case uri
                case mimeType = "mime_type"
            }
        }

        struct GenerationConfiguration: Encodable {
            struct TranscriptionConfiguration: Encodable {
                struct Mode: Encodable {
                    let type: String
                }

                let languageCodes: [String]
                let customVocabulary: [String]
                let mode: Mode

                enum CodingKeys: String, CodingKey {
                    case languageCodes = "language_codes"
                    case customVocabulary = "custom_vocabulary"
                    case mode
                }
            }

            let transcriptionConfig: TranscriptionConfiguration

            enum CodingKeys: String, CodingKey {
                case transcriptionConfig = "transcription_config"
            }
        }

        let model: String
        let input: [AudioInput]
        let generationConfig: GenerationConfiguration
        let store = false

        enum CodingKeys: String, CodingKey {
            case model
            case input
            case generationConfig = "generation_config"
            case store
        }
    }

    struct InteractionResponse: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }

        struct Step: Decodable {
            let content: [Content]?
        }

        let outputText: String?
        let outputs: [Content]?
        let steps: [Step]?

        enum CodingKeys: String, CodingKey {
            case outputText = "output_text"
            case outputs
            case steps
        }

        var transcript: String? {
            let directText = outputText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let directText, !directText.isEmpty {
                return directText
            }

            let content = outputs ?? steps?.flatMap { $0.content ?? [] }
            let text = content?
                .filter { $0.type == nil || $0.type == "text" }
                .compactMap(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
    }

    static func customVocabulary(from vocabulary: [String]) -> [String] {
        Array(CustomVocabulary.normalized(vocabulary).prefix(1_000))
    }

    static func languageCodes(from hints: [String]) -> [String] {
        var seen: Set<String> = []
        return hints.compactMap { hint in
            let normalized = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }

            let code: String?
            if normalized.contains("-") {
                code = supportedLanguageCodes.first {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                }
            } else {
                code = defaultLanguageCodes[normalized.lowercased()]
            }

            guard let code, seen.insert(code).inserted else { return nil }
            return code
        }
    }

    private static let supportedLanguageCodes: Set<String> = Set(defaultLanguageCodes.values).union([
        "bn-BD", "en-GB", "en-IN", "es-US", "pa-Guru-IN", "pt-BR",
    ])

    private static let defaultLanguageCodes: [String: String] = [
        "af": "af-ZA", "am": "am-ET", "ar": "ar-EG", "as": "as-IN",
        "az": "az-AZ", "be": "be-BY", "bg": "bg-BG", "bn": "bn-IN",
        "bs": "bs-BA", "ca": "ca-ES", "ceb": "ceb", "cmn": "cmn-Hans-CN",
        "cs": "cs-CZ", "da": "da-DK", "de": "de-DE", "el": "el-GR",
        "en": "en-US", "es": "es-419", "et": "et-EE", "fa": "fa-IR",
        "fi": "fi-FI", "fil": "fil-PH", "fr": "fr-FR", "gl": "gl-ES",
        "gu": "gu-IN", "ha": "ha-NG", "he": "he-IL", "hi": "hi-IN",
        "hr": "hr-HR", "hu": "hu-HU", "hy": "hy-AM", "id": "id-ID",
        "is": "is-IS", "it": "it-IT", "ja": "ja-JP", "jv": "jv-ID",
        "ka": "ka-GE", "kea": "kea-CV", "kk": "kk-KZ", "km": "km-KH",
        "kn": "kn-IN", "ko": "ko-KR", "ky": "ky-KG", "ln": "ln-CD",
        "lt": "lt-LT", "lv": "lv-LV", "mk": "mk-MK", "ml": "ml-IN",
        "mn": "mn-MN", "mr": "mr-IN", "ms": "ms-MY", "mt": "mt-MT",
        "my": "my-MM", "nb": "nb-NO", "ne": "ne-NP", "nl": "nl-NL",
        "no": "nb-NO", "or": "or-IN", "pa": "pa-IN", "pl": "pl-PL",
        "pt": "pt-PT", "ro": "ro-RO", "ru": "ru-RU", "rup": "rup-BG",
        "sd": "sd-Arab-IN", "sk": "sk-SK", "sl": "sl-SI", "sr": "sr-RS",
        "sv": "sv-SE", "sw": "sw-KE", "te": "te-IN",
        "tg": "tg-TJ", "th": "th-TH", "tl": "fil-PH", "tr": "tr-TR",
        "uk": "uk-UA", "uz": "uz-UZ", "vi": "vi-VN", "yue": "yue-Hant-HK",
        "zh": "cmn-Hans-CN",
    ]
}
