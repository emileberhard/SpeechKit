import Foundation

enum AssemblyAIAPI {
    struct UploadResponse: Decodable {
        let upload_url: String
    }

    struct TranscriptResponse: Decodable {
        let id: String
    }

    struct StatusResponse: Decodable {
        let status: String
        let text: String?
        let error: String?
    }

    struct TranscriptRequest: Encodable {
        let audio_url: String
        let speech_models: [String]
        let language_code: String?
        let language_detection: Bool?
        let language_detection_options: LanguageDetectionOptions?
        let keyterms_prompt: [String]?

        struct LanguageDetectionOptions: Encodable {
            let expected_languages: [String]
        }
    }
}
