import Foundation

enum OpenAIAPI {
    struct TranscriptionResponse: Decodable {
        let text: String
    }
}
