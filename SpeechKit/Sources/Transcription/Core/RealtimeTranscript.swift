import Foundation

public struct RealtimeTranscript: Sendable, Equatable {
    public private(set) var text: String?

    public init() {}

    @discardableResult
    public mutating func append(_ committedText: String) -> Bool {
        let segment = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptSoundEvents.containsSpeech(segment) else { return false }
        text = text.map { "\($0) \(segment)" } ?? segment
        return true
    }
}

public enum TranscriptSoundEvents {
    public static func containsSpeech(_ text: String) -> Bool {
        let withoutTags = text.replacing(/\[[^\[\]]*\]/, with: "")
        return withoutTags.contains { $0.isLetter || $0.isNumber }
    }
}
