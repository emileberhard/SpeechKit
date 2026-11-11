import Foundation

public nonisolated struct SpeakerPhrase: Equatable, Sendable {
    public let speaker: Int
    public let text: String
    public let words: [Range<Duration>]

    public init(speaker: Int, text: String, words: [Range<Duration>]) {
        self.speaker = speaker
        self.text = text
        self.words = words
    }
}
