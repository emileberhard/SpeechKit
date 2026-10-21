import Foundation

enum GeminiAPI {
    static let maximumInlineRequestBytes = 20_000_000
    static let inlineRequestBytesReservedForPrompt = 1_000_000
    static let maximumInlineAudioBytes = (maximumInlineRequestBytes - inlineRequestBytesReservedForPrompt) / 4 * 3

    struct GenerateContentRequest: Encodable {
        let contents: [Content]
        let generationConfig: GenerationConfig

        struct Content: Encodable {
            let parts: [Part]
        }

        struct GenerationConfig: Encodable {
            let thinkingConfig: ThinkingConfig

            struct ThinkingConfig: Encodable {
                let thinkingLevel: String
            }
        }
    }

    enum Part: Encodable {
        case text(String)
        case inlineData(mimeType: String, data: String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode(text, forKey: .text)
            case .inlineData(let mimeType, let data):
                try container.encode(InlineData(mimeType: mimeType, data: data), forKey: .inlineData)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case inlineData
        }

        private struct InlineData: Encodable {
            let mimeType: String
            let data: String
        }
    }

    struct GenerateContentResponse: Decodable {
        let candidates: [Candidate]?

        struct Candidate: Decodable {
            let content: Content?

            struct Content: Decodable {
                let parts: [Part]?

                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
            }
        }
    }
}
