import Foundation

public struct TranscriptionResult: Sendable {
    public let text: String
    public let providerID: String
    public let modelID: String?
    public let languageCode: String?
    public let warnings: [String]

    public init(
        text: String,
        providerID: String,
        modelID: String? = nil,
        languageCode: String? = nil,
        warnings: [String] = []
    ) {
        self.text = text
        self.providerID = providerID
        self.modelID = modelID
        self.languageCode = languageCode
        self.warnings = warnings
    }
}
