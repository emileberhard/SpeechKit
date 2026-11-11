import Foundation

nonisolated public struct VoiceProfile: Codable, Equatable, Sendable {
    static let learningThreshold: Float = 0.5
    static let readyCandidates = 5
    static let maximumExemplars = 24
    private static let updateMatches = 3
    private static let recentWindow = 10
    private static let resetMisses = 8

    let modelVersion: String
    let createdAt: Date
    private(set) var candidates: [SpeakerEmbedding] = []
    private(set) var exemplars: [SpeakerEmbedding] = []
    private(set) var recentMatches: [Bool] = []
    private(set) var historySince: Date?

    init(modelVersion: String, createdAt: Date) {
        self.modelVersion = modelVersion
        self.createdAt = createdAt
    }

    public var learnedSince: Date { historySince ?? createdAt }
    public var isTrusted: Bool { recentMatches.count == Self.recentWindow && !recentMatches.contains(false) }
    var isFrozen: Bool { exemplars.count >= Self.maximumExemplars }
    var mean: SpeakerEmbedding? { SpeakerEmbedding.mean(of: exemplars) }
    var trustedMean: SpeakerEmbedding? { isTrusted ? mean : nil }

    mutating func learn(_ candidate: SpeakerEmbedding, at date: Date) {
        guard let mean else { return collect(candidate) }
        recentMatches = Array((recentMatches + [candidate.similarity(to: mean) >= VoiceFilter.sameVoiceThreshold]).suffix(Self.recentWindow))
        if recentMatches.count(where: { !$0 }) >= Self.resetMisses {
            self = VoiceProfile(modelVersion: modelVersion, createdAt: date)
            return
        }
        guard !isFrozen else { return }
        let best = exemplars.map { candidate.similarity(to: $0) }.sorted(by: >).prefix(Self.updateMatches)
        if best.reduce(0, +) / Float(best.count) >= Self.learningThreshold { exemplars.append(candidate) }
    }

    mutating func learnHistory(_ candidates: [VoiceHistoryCandidate], at date: Date) {
        let since = candidates.map(\.startedAt).min() ?? createdAt
        for candidate in candidates { learn(candidate.embedding, at: date) }
        historySince = since
    }

    private mutating func collect(_ candidate: SpeakerEmbedding) {
        candidates.append(candidate)
        guard candidates.count >= Self.readyCandidates else { return }
        let scores = candidates.indices.map { index in
            var others = candidates
            others.remove(at: index)
            return SpeakerEmbedding.mean(of: others).map { candidates[index].similarity(to: $0) } ?? 0
        }
        guard let worst = scores.indices.min(by: { scores[$0] < scores[$1] }), scores[worst] < Self.learningThreshold else {
            exemplars = candidates
            candidates = []
            return
        }
        candidates.remove(at: worst)
    }
}

public actor VoiceProfileStore {
    private let url: URL
    private var cached: VoiceProfile?
    private var forgottenAt: Date?

    public init(accountDirectory: URL) {
        url = accountDirectory.appendingPathComponent("VoiceProfile.json", isDirectory: false)
    }

    public func profile() throws -> VoiceProfile {
        try loaded()
    }

    func learn(_ candidate: SpeakerEmbedding, startedAt: Date) throws {
        if let forgottenAt, startedAt < forgottenAt { return }
        var profile = try loaded()
        let before = profile
        profile.learn(candidate, at: .now)
        guard profile != before else { return }
        try write(profile)
        cached = profile
    }

    public func beginHistory() throws -> VoiceHistoryWindow? {
        var profile = try loaded()
        guard profile.historySince == nil else { return nil }
        guard !profile.isTrusted else {
            profile.learnHistory([], at: .now)
            try write(profile)
            cached = profile
            return nil
        }
        return VoiceHistoryWindow(start: forgottenAt ?? .distantPast, end: profile.createdAt)
    }

    public func learnHistory(_ candidates: [VoiceHistoryCandidate], in window: VoiceHistoryWindow) throws -> VoiceProfile? {
        var profile = try loaded()
        guard profile.createdAt == window.end, profile.historySince == nil else { return nil }
        profile.learnHistory(candidates.filter { $0.startedAt >= forgottenAt ?? .distantPast }, at: .now)
        try write(profile)
        cached = profile
        return profile
    }

    public func forget(learnedBefore date: Date) throws {
        forgottenAt = max(forgottenAt ?? date, date)
        guard try loaded().learnedSince < date else { return }
        try discard(createdAt: date)
    }

    private func loaded() throws -> VoiceProfile {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else { return remember(VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)) }
        let data = try Data(contentsOf: url)
        guard let stored = try? JSONDecoder().decode(VoiceProfile.self, from: data) else {
            try discard(createdAt: .now)
            throw VoiceFilterError.profileUnreadable
        }
        guard stored.modelVersion == SpeakerEmbedder.modelVersion else {
            try discard(createdAt: .now)
            return try loaded()
        }
        return remember(stored)
    }

    private func discard(createdAt date: Date) throws {
        cached = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: date)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func remember(_ profile: VoiceProfile) -> VoiceProfile {
        cached = profile
        return profile
    }

    private func write(_ profile: VoiceProfile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(profile).write(to: url, options: options)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}
