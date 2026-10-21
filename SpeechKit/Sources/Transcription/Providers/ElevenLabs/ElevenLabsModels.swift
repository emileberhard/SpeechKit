import Foundation

enum ElevenLabsAPI {
    struct ChunkResponse: Decodable {
        let text: String
    }

    struct MultichannelResponse: Decodable {
        let transcripts: [ChunkResponse]
    }

    struct WebhookResponse: Decodable {
        let message: String
        let request_id: String
        let transcription_id: String
    }

    enum BatchResponse: Decodable {
        case chunk(ChunkResponse)
        case multichannel(MultichannelResponse)
        case webhook(WebhookResponse)

        init(from decoder: Decoder) throws {
            if let chunk = try? ChunkResponse(from: decoder) {
                self = .chunk(chunk)
                return
            }

            if let multichannel = try? MultichannelResponse(from: decoder) {
                self = .multichannel(multichannel)
                return
            }

            if let webhook = try? WebhookResponse(from: decoder) {
                self = .webhook(webhook)
                return
            }

            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown ElevenLabs response shape")
            )
        }
    }

}
