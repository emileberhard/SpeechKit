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
    static let minimumJudgedMilliseconds = 1_000
    private static let longLabelMilliseconds = 2_000
    private static let shortAnchorThreshold: Float = 0.5
    private static let shortRejectionThreshold: Float = 0.25
    private static let mergeGapMilliseconds = 150
    private static let paddingMilliseconds = 50
    private static let windowMilliseconds = SpeakerEmbedder.windowSamples * 1_000 / KaldiFilterbank.sampleRate

    static func labels(in phrases: [SpeakerPhrase]) -> [SpeakerLabel] {
        let words = Dictionary(grouping: phrases, by: \.speaker).mapValues { phrases in
            phrases.flatMap(\.words).compactMap { word -> Range<Int>? in
                guard let start = milliseconds(word.lowerBound), let end = milliseconds(word.upperBound), end > start else { return nil }
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

    static func keptSpeakers(of labels: [SpeakerLabel], embeddings: [Int: SpeakerEmbedding], profile: SpeakerEmbedding,
                             dropsUnjudged: Bool) -> Set<Int>? {
        let judged = labels.filter(\.isJudged).compactMap { label in
            embeddings[label.speaker].map { (label: label, embedding: $0) }
        }
        let anchors = judged.filter {
            $0.embedding.similarity(to: profile) >= ($0.label.speechMilliseconds < longLabelMilliseconds ? shortAnchorThreshold : sameVoiceThreshold)
        }
        guard let anchor = anchors.max(by: { $0.embedding.similarity(to: profile) < $1.embedding.similarity(to: profile) }) else { return nil }
        let rejected = judged.filter { label, embedding in
            let threshold = label.speechMilliseconds < longLabelMilliseconds ? shortRejectionThreshold : sameVoiceThreshold
            return label.speaker != anchor.label.speaker
                && embedding.similarity(to: anchor.embedding) < threshold
                && embedding.similarity(to: profile) < threshold
        }.map { $0.label.speaker }
        let unjudged = dropsUnjudged ? labels.filter { !$0.isJudged && $0.speaker != anchor.label.speaker }.map(\.speaker) : []
        let dropped = Set(rejected + unjudged)
        guard !dropped.isEmpty else { return nil }
        return Set(labels.map(\.speaker)).subtracting(dropped)
    }

    static func spokenLines(in transcript: String) -> Int {
        transcript.split(whereSeparator: \.isNewline).count { $0.contains { !$0.isWhitespace } }
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

    private static func milliseconds(_ duration: Duration) -> Int? {
        guard duration >= .zero else { return nil }
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !seconds.overflow else { return nil }
        let total = seconds.partialValue.addingReportingOverflow(components.attoseconds / 1_000_000_000_000_000)
        guard !total.overflow, let value = Int(exactly: total.partialValue),
              value <= Int.max / KaldiFilterbank.sampleRate - paddingMilliseconds else { return nil }
        return value
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
