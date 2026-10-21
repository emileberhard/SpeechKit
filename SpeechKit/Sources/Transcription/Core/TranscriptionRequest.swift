import Foundation

public struct TranscriptionAudio: Sendable {
    public let data: Data
    public let fileName: String
    public let mimeType: String
    public let fileExtension: String

    public init(data: Data, fileName: String, mimeType: String, fileExtension: String) throws {
        guard !data.isEmpty else {
            throw SpeechKitError.invalidRequest("Audio payload is empty")
        }
        guard !fileName.isEmpty else {
            throw SpeechKitError.invalidRequest("File name is required")
        }
        guard !mimeType.isEmpty else {
            throw SpeechKitError.invalidRequest("MIME type is required")
        }
        guard !fileExtension.isEmpty else {
            throw SpeechKitError.invalidRequest("File extension is required")
        }

        self.data = data
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileExtension = fileExtension
    }
}

public struct TranscriptionRequest: Sendable {
    public let audio: TranscriptionAudio
    public let languageHints: [String]
    public let customVocabulary: [String]
    public let instructions: String?

    public init(
        audio: TranscriptionAudio,
        languageHints: [String],
        customVocabulary: [String],
        instructions: String? = nil
    ) {
        self.audio = audio
        self.languageHints = languageHints
        self.customVocabulary = customVocabulary
        self.instructions = instructions
    }
}
