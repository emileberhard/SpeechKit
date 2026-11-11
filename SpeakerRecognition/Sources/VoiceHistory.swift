import Foundation

nonisolated public struct VoiceHistoryRecording: Sendable {
    public let url: URL
    public let startedAt: Date
    public let finishedAt: Date
    public init(url: URL, startedAt: Date, finishedAt: Date) {
        self.url = url
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

}

nonisolated public struct VoiceHistoryWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date
}

nonisolated public struct VoiceHistoryCandidate: Sendable {
    let embedding: SpeakerEmbedding
    public let startedAt: Date
}

nonisolated public struct VoiceHistory: Sendable {
    private static let recordingLimit = 100
    private static let candidateLimit = 30
    private static let longestRecording: TimeInterval = 120

    public private(set) var candidates: [VoiceHistoryCandidate] = []
    public private(set) var checked = 0
    public private(set) var unreadable = 0

    @concurrent
    public static func learn(from recordings: [VoiceHistoryRecording], in window: VoiceHistoryWindow, decode: @Sendable (URL) async throws -> Data) async throws -> VoiceHistory {
        let shortest = TimeInterval(VoiceRecording.minimumLearningSamples) / TimeInterval(KaldiFilterbank.sampleRate)
        let eligible = recordings
            .filter { $0.startedAt >= window.start && $0.finishedAt < window.end }
            .filter { (shortest...longestRecording).contains($0.finishedAt.timeIntervalSince($0.startedAt)) }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(recordingLimit)
        var history = VoiceHistory()
        guard !eligible.isEmpty else { return history }
        let embedder = try SpeakerEmbedder(modelURL: try SpeakerEmbedder.requireModelURL())
        for recording in eligible where history.candidates.count < candidateLimit {
            try Task.checkCancellation()
            history.checked += 1
            let pcm: Data
            do { pcm = try await decode(recording.url) } catch {
                history.unreadable += 1
                continue
            }
            var listener = VoiceListener(embedder: embedder, profile: nil)
            try await listener.append(pcm)
            if let embedding = try await listener.finish().learningCandidate() {
                history.candidates.insert(VoiceHistoryCandidate(embedding: embedding, startedAt: recording.startedAt), at: 0)
            }
        }
        return history
    }
}
