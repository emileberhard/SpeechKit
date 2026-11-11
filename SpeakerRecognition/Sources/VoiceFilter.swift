import Foundation
import SpeechKit

nonisolated struct SpeakerLabel: Equatable, Sendable {
    let speaker: Int
    let speechMilliseconds: Int
    let evidence: [Range<Int>]

    var isJudged: Bool { speechMilliseconds >= VoiceFilter.minimumJudgedMilliseconds }

    func evidenceSamples(sampleRate: Int) -> [Range<Int>] {
        evidence.map { $0.lowerBound * sampleRate / 1_000..<$0.upperBound * sampleRate / 1_000 }
    }
}

nonisolated enum VoiceFilter {
    static let sameVoiceThreshold: Float = 0.35
    static let minimumJudgedMilliseconds = 2_000
    private static let mergeGapMilliseconds = 150
    private static let paddingMilliseconds = 50
    private static let windowMilliseconds = SpeakerEmbedder.windowSamples * 1_000 / KaldiFilterbank.sampleRate

    static func labels(in phrases: [SpeakerPhrase]) -> [SpeakerLabel] {
        let words = Dictionary(grouping: phrases, by: \.speaker).mapValues { phrases in
            phrases.flatMap(\.words).compactMap { word -> Range<Int>? in
                let start = Int(word.lowerBound / .milliseconds(1))
                let end = Int(word.upperBound / .milliseconds(1))
                guard start >= 0, end > start else { return nil }
                return start..<end
            }
        }
        return words.keys.sorted().map { speaker in
            let spans = merged(words[speaker] ?? [])
            var remaining = windowMilliseconds
            let evidence = spans
                .map { max(0, $0.lowerBound - paddingMilliseconds)..<$0.upperBound + paddingMilliseconds }
                .sorted { $0.count > $1.count }
                .compactMap { span -> Range<Int>? in
                    guard remaining > 0 else { return nil }
                    defer { remaining -= span.count }
                    return span.lowerBound..<span.lowerBound + min(span.count, remaining)
                }
            return SpeakerLabel(speaker: speaker, speechMilliseconds: spans.reduce(0) { $0 + $1.count }, evidence: evidence)
        }
    }

    static func keptSpeakers(of labels: [SpeakerLabel], embeddings: [Int: SpeakerEmbedding], profile: SpeakerEmbedding) -> Set<Int>? {
        let judged = labels.filter(\.isJudged).compactMap { label in embeddings[label.speaker].map { (label.speaker, $0) } }
        guard let anchor = judged.max(by: { $0.1.similarity(to: profile) < $1.1.similarity(to: profile) }),
              anchor.1.similarity(to: profile) >= sameVoiceThreshold else { return nil }
        let dropped = Set(judged.filter { speaker, embedding in
            speaker != anchor.0
                && embedding.similarity(to: anchor.1) < sameVoiceThreshold
                && embedding.similarity(to: profile) < sameVoiceThreshold
        }.map(\.0))
        guard !dropped.isEmpty else { return nil }
        return Set(labels.map(\.speaker)).subtracting(dropped)
    }

    static func text(of phrases: [SpeakerPhrase]) -> String {
        text(of: phrases, keeping: Set(phrases.map(\.speaker)))
    }

    static func text(of phrases: [SpeakerPhrase], keeping speakers: Set<Int>) -> String {
        phrases.filter { speakers.contains($0.speaker) }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func merged(_ spans: [Range<Int>]) -> [Range<Int>] {
        spans.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, span in
            if let last = merged.last, span.lowerBound - last.upperBound <= mergeGapMilliseconds {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
    }
}
