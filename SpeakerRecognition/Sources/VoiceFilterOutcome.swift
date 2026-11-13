import Foundation
import SpeechKit

nonisolated public enum VoiceFilterStage: String, Sendable {
    case filter
    case learning
}

nonisolated public struct VoiceFilterOutcome: Sendable {
    public enum Path: String, Sendable {
        case notHeard = "not_heard"
        case tooLong = "too_long"
        case undecided
        case keptEveryone = "kept_everyone"
        case filtered
        case failed
    }

    public let path: Path
    public let labelCount: Int
    public let droppedCount: Int

    static let notHeard = Self(path: .notHeard, labelCount: 0, droppedCount: 0)
    static let tooLong = Self(path: .tooLong, labelCount: 0, droppedCount: 0)
    public static let undecided = Self(path: .undecided, labelCount: 0, droppedCount: 0)
    public static let failed = Self(path: .failed, labelCount: 0, droppedCount: 0)

}

extension VoiceFilter {
    @concurrent static func apply(_ phrases: [SpeakerPhrase], everyone: String, marksAnotherSpeaker: Bool, audio: SpeakerAudio,
                                  profile: SpeakerEmbedding) async throws -> (text: String, outcome: VoiceFilterOutcome)
    {
        let labels = labels(in: phrases)
        var embeddings: [Int: SpeakerEmbedding] = [:]
        for label in labels where label.isJudged {
            embeddings[label.speaker] = try await audio.embedding(of: label.evidenceSamples(sampleRate: KaldiFilterbank.sampleRate))
        }
        guard let kept = keptSpeakers(of: labels, embeddings: embeddings, profile: profile, dropsUnjudged: marksAnotherSpeaker) else {
            return (everyone, VoiceFilterOutcome(path: .keptEveryone, labelCount: labels.count, droppedCount: 0))
        }
        return (text(of: phrases, keeping: kept), VoiceFilterOutcome(path: .filtered, labelCount: labels.count,
                                                                    droppedCount: labels.count - kept.count))
    }
}
