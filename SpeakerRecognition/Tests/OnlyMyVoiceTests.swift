import AVFoundation
import Foundation
import SpeechKit
import Testing
@testable import SpeakerRecognition

enum SpeakerFixtures {
    struct Reference: Decodable {
        let modelVersion: String
        let syntheticFbankRows: [String: [Float]]
        let syntheticFbankFrameCount: Int
        let embeddings: [String: [Float]]
    }

    static func reference() throws -> Reference {
        try JSONDecoder().decode(Reference.self, from: Data(contentsOf: Bundle.module.url(forResource: "SpeakerModelReference", withExtension: "json")!))
    }

    static func modelURL() throws -> URL {
        try #require(SpeakerEmbedder.bundledModelURL)
    }

    static func embedder() throws -> SpeakerEmbedder {
        try SpeakerEmbedder(modelURL: modelURL())
    }

    static func speech(_ name: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: Bundle.module.url(forResource: name, withExtension: "wav")!)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try #require(AVAudioConverter(from: file.processingFormat, to: format))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1_024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        converter.convert(to: output, error: &failure) { _, status in
            defer { supplied = true }
            status.pointee = supplied ? .endOfStream : .haveData
            return supplied ? nil : source
        }
        if let failure { throw failure }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static let silence = [Float](repeating: 0, count: 16_000)
}

nonisolated private func axis(_ index: Int, _ weight: Float = 1, plus other: Int? = nil, _ otherWeight: Float = 0) -> SpeakerEmbedding {
    var values = [Float](repeating: 0, count: 256)
    values[index] = weight
    if let other { values[other] += otherWeight }
    return SpeakerEmbedding(normalizing: values)
}

@Suite("Speaker model")
struct SpeakerModelTests {
    @Test func theFilterbankMatchesKaldiOnTheReferenceSignal() throws {
        let reference = try SpeakerFixtures.reference()
        let samples = (0..<16_000).map { n -> Float in
            let n = Double(n)
            let noise = Double((Int(n) * 7_919) % 1_000) / 1_000 - 0.5
            return Float(0.3 * sin(2 * .pi * 220 * n / 16_000) + 0.2 * sin(2 * .pi * 1_375 * n / 16_000 + 0.5) + 0.05 * noise)
        }
        let features = try KaldiFilterbank.features(of: samples)
        #expect(features.count == reference.syntheticFbankFrameCount * KaldiFilterbank.binCount)
        for (row, expected) in reference.syntheticFbankRows {
            let start = try #require(Int(row)) * KaldiFilterbank.binCount
            let produced = features[start..<start + KaldiFilterbank.binCount]
            #expect(zip(produced, expected).allSatisfy { abs($0 - $1) < 0.01 }, "row \(row)")
        }
    }

    @Test func theBundledModelEmbedsSpeechLikeTheReference() async throws {
        let reference = try SpeakerFixtures.reference()
        #expect(reference.modelVersion == SpeakerEmbedder.modelVersion)
        let embedder = try SpeakerFixtures.embedder()
        for (name, expected) in reference.embeddings {
            let produced = try await embedder.embedding(of: Array(try SpeakerFixtures.speech(name).prefix(SpeakerEmbedder.windowSamples)))
            #expect(produced.similarity(to: SpeakerEmbedding(normalizing: expected)) >= 0.99, "\(name)")
        }
    }
}

@Suite("Voice watch")
struct VoiceWatchTests {
    @Test func piecesEndAtPausesAndAtTheWindow() {
        var signal = [Float](repeating: 0.001, count: 16_000)
        for _ in 0..<3 {
            signal += (0..<32_000).map { 0.3 * sin(Float($0) * 0.2) }
            signal += [Float](repeating: 0.001, count: 16_000)
        }
        signal += (0..<400_000).map { 0.3 * sin(Float($0) * 0.2) }
        var segmenter = VoicedPieceSegmenter()
        var pieces: [Range<Int>] = []
        for start in stride(from: 0, to: signal.count, by: 1_600) {
            pieces += segmenter.append(Array(signal[start..<min(start + 1_600, signal.count)]))
        }
        pieces += segmenter.finish().map { [$0] } ?? []

        #expect(pieces.count == 6)
        for piece in pieces.prefix(3) { #expect(abs(piece.count - 32_000) <= 800) }
        #expect(pieces.dropFirst(3).map(\.count).prefix(2).allSatisfy { $0 <= 160_000 && $0 > 158_000 })
    }

    @Test func aContinuousMixRequestsLabelsAgainstTheTrustedProfile() async throws {
        let embedder = try SpeakerFixtures.embedder()
        func voiced(_ name: String) throws -> [Float] {
            let samples = try SpeakerFixtures.speech(name)
            return stride(from: 0, through: samples.count - 160, by: 160).flatMap { start -> [Float] in
                let frame = samples[start..<start + 160]
                let rms = sqrt(frame.reduce(Float.zero) { $0 + $1 * $1 } / 160)
                return rms > 0.02 ? frame.map { $0 * 0.1 / rms } : []
            }
        }
        let mine = try voiced("en-teen-note")
        let other = try voiced("en-landlord-email")
        let profile = try await embedder.embedding(of: mine)
        let mix = Array(other.prefix(64_000)) + Array(mine.prefix(48_000))
        var listener = VoiceListener(embedder: embedder, profile: profile)
        let pcm = SpeakerFixtures.pcm16(mix)
        for start in stride(from: 0, to: pcm.count, by: 3_200) {
            try await listener.append(pcm.subdata(in: start..<min(start + 3_200, pcm.count)))
        }
        let recording = try await listener.finish()
        #expect(recording.pieces.count == 1)
        #expect(recording.requestsLabels)
        #expect(recording.containsMixedVoices)
        #expect(try await recording.learningCandidate() == nil)
    }

    @Test func aCoherentMismatchRepairsATrustedFrozenProfile() async throws {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .distantPast)
        for _ in 0..<40 { profile.learn(axis(0), at: .distantPast) }
        #expect(profile.isTrusted && profile.isFrozen)
        let embedder = try SpeakerFixtures.embedder()
        let other = try SpeakerFixtures.speech("en-developer-message")
        var listener = VoiceListener(embedder: embedder, profile: profile.trustedMean)
        try await listener.append(SpeakerFixtures.pcm16(other))
        let recording = try await listener.finish()
        #expect(!recording.requestsLabels)
        #expect(!recording.containsMixedVoices)
        let candidate = try #require(try await recording.learningCandidate())
        #expect(candidate.similarity(to: try #require(profile.mean)) < VoiceFilter.sameVoiceThreshold)
        for _ in 0..<7 { profile.learn(candidate, at: .now) }
        #expect(profile.isFrozen && !profile.isTrusted)
        profile.learn(candidate, at: .now)
        #expect(profile.mean == nil && !profile.isTrusted)
    }

    @Test func anotherVoiceIsHeardOnlyWhenOneSpeaks() async throws {
        let modelURL = try SpeakerFixtures.modelURL()
        func watch(_ names: [String]) async throws -> VoiceRecording {
            let watch = VoiceWatch(modelURL: modelURL, profile: nil)
            var samples: [Float] = []
            for name in names { samples += try SpeakerFixtures.speech(name) + SpeakerFixtures.silence }
            let pcm = SpeakerFixtures.pcm16(samples)
            for offset in stride(from: 0, to: pcm.count, by: 3_200) { watch.append(pcm.subdata(in: offset..<min(offset + 3_200, pcm.count))) }
            watch.finish()
            return try await watch.recording
        }

        let one = try await watch(["en-developer-message", "en-short-long-rushed"])
        #expect(one.isComplete && one.pieces.count >= 2)
        #expect(!one.otherVoiceHeard)
        #expect(try await one.learningCandidate() != nil)

        let two = try await watch(["en-teen-note", "en-landlord-email"])
        #expect(two.otherVoiceHeard)
        #expect(try await two.learningCandidate() == nil)

        let interrupted = try await watch(["en-short-long-rushed", "en-teen-note"])
        let scores = interrupted.pieces.indices.map { index in
            var others = interrupted.pieces
            others.remove(at: index)
            let reference = SpeakerEmbedding.mean(of: others.map(\.embedding), weights: others.map { Float($0.samples.count) })
            return reference.map { interrupted.pieces[index].embedding.similarity(to: $0) } ?? 1
        }
        #expect(interrupted.otherVoiceHeard, "\(interrupted.pieces.map(\.samples)) \(scores)")
    }
}

@Suite("Voice filter")
struct VoiceFilterTests {
    private func phrase(_ speaker: Int, _ text: String, seconds: Double, at start: Int = 0) -> SpeakerPhrase {
        let words = stride(from: 0, to: Int(seconds * 1_000), by: 500).map {
            Duration.milliseconds(start + $0) ..< Duration.milliseconds(start + $0 + 400)
        }
        return SpeakerPhrase(speaker: speaker, text: text, words: words)
    }

    @Test func labelsMergeCloseWordsAndKeepTheLongestEvidenceFirst() {
        let labels = VoiceFilter.labels(in: [
            SpeakerPhrase(speaker: 0, text: "a", words: [.milliseconds(0) ..< .milliseconds(400), .milliseconds(500) ..< .milliseconds(800)]),
            SpeakerPhrase(speaker: 1, text: "b", words: [.milliseconds(900) ..< .milliseconds(1100)]),
            SpeakerPhrase(speaker: 0, text: "c", words: [.milliseconds(2000) ..< .milliseconds(3500)]),
        ])
        #expect(labels == [
            SpeakerLabel(speaker: 0, speechMilliseconds: 2_300, evidence: [1_950..<3_550, 0..<850]),
            SpeakerLabel(speaker: 1, speechMilliseconds: 200, evidence: [850..<1_150]),
        ])
        #expect(labels[0].isJudged && !labels[1].isJudged)
        #expect(labels[0].evidenceSamples(sampleRate: 16_000).first == 31_200..<56_800)
    }

    @Test func evidenceStopsAtTheModelWindow() {
        let label = VoiceFilter.labels(in: [SpeakerPhrase(speaker: 0, text: "a", words: [.milliseconds(0) ..< .milliseconds(6000), .milliseconds(7000) ..< .milliseconds(13000)])])[0]
        #expect(label.evidence.reduce(0) { $0 + $1.count } == 10_000)
    }

    @Test func shortTurnsNeedAStrongAnchorAndTwoClearRejections() {
        let labels = [
            SpeakerLabel(speaker: 0, speechMilliseconds: 1_200, evidence: []),
            SpeakerLabel(speaker: 1, speechMilliseconds: 1_500, evidence: []),
            SpeakerLabel(speaker: 2, speechMilliseconds: 1_100, evidence: []),
            SpeakerLabel(speaker: 3, speechMilliseconds: 999, evidence: []),
            SpeakerLabel(speaker: 4, speechMilliseconds: 1_400, evidence: []),
        ]
        let embeddings = [
            0: axis(0, 0.8, plus: 9, 0.6),
            1: axis(1, 1, plus: 0, 0.1),
            2: axis(2, 1, plus: 0, 0.3),
            3: axis(3),
            4: axis(0, 0.4, plus: 4, 0.9165),
        ]
        #expect(VoiceFilter.keptSpeakers(of: labels, embeddings: embeddings, profile: axis(0)) == [0, 2, 3, 4])
        #expect(VoiceFilter.keptSpeakers(of: Array(labels.dropFirst()), embeddings: embeddings, profile: axis(0)) == nil)
    }

    @Test func anotherPersonIsDroppedAndShortLabelsAreKept() {
        let phrases = [phrase(0, "Mine.", seconds: 5), phrase(1, "Theirs.", seconds: 3, at: 6_000), phrase(2, "Hm?", seconds: 1, at: 10_000)]
        let labels = VoiceFilter.labels(in: phrases)
        let kept = VoiceFilter.keptSpeakers(of: labels, embeddings: [0: axis(0), 1: axis(1)], profile: axis(0))
        #expect(kept == [0, 2])
        #expect(VoiceFilter.text(of: phrases, keeping: kept ?? []) == "Mine. Hm?")
    }

    @Test(arguments: [
        ("a split user", [0: axis(0), 1: axis(0, 0.6, plus: 2, 0.8)]),
        ("the user's other label matches only this recording", [0: axis(0, 0.8, plus: 3, 0.6), 1: axis(3)]),
        ("the user is not recognizably there", [0: axis(1), 1: axis(2)]),
        ("nothing long enough to judge", [:]),
    ] as [(String, [Int: SpeakerEmbedding])])
    func everythingIsKeptWhenNoLabelIsRejectedTwice(_ name: String, embeddings: [Int: SpeakerEmbedding]) {
        let labels = VoiceFilter.labels(in: [phrase(0, "a", seconds: 4), phrase(1, "b", seconds: 4, at: 5_000)])
        #expect(VoiceFilter.keptSpeakers(of: labels, embeddings: embeddings, profile: axis(0)) == nil, "\(name)")
    }


}

@Suite("Voice profile")
struct VoiceProfileTests {
    private func near(_ index: Int, _ seed: Int) -> SpeakerEmbedding {
        axis(index, 1, plus: 10 + seed, 0.2)
    }

    private func readyProfile() -> VoiceProfile {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for seed in 0..<5 { profile.learn(near(0, seed), at: .now) }
        return profile
    }

    @Test func fiveConsistentCandidatesMakeItReadyAndAnOutlierIsDropped() throws {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for seed in 0..<4 { profile.learn(near(0, seed), at: .now) }
        profile.learn(axis(1), at: .now)
        #expect(profile.mean == nil && profile.candidates.count == 4)
        profile.learn(near(0, 4), at: .now)
        #expect(profile.mean != nil && profile.exemplars.count == 5)
        #expect(try #require(profile.mean).similarity(to: axis(0)) > 0.9)
    }

    @Test func aReadyProfileAcceptsOnlyItsOwnVoiceAndFreezes() {
        var profile = readyProfile()
        profile.learn(axis(1), at: .now)
        #expect(profile.exemplars.count == 5)
        for seed in 5..<40 { profile.learn(near(0, seed), at: .now) }
        #expect(profile.isFrozen && profile.exemplars.count == VoiceProfile.maximumExemplars)
    }

    @Test func itIsTrustedOnlyOnceTheLastTenDictationsMatch() {
        var profile = readyProfile()
        for seed in 5..<14 { profile.learn(near(0, seed), at: .now) }
        #expect(profile.mean != nil && !profile.isTrusted && profile.trustedMean == nil)
        profile.learn(near(0, 14), at: .now)
        #expect(profile.isTrusted && profile.trustedMean != nil)
    }

    @Test(arguments: [2, 5])
    func aDeviceSharedWithAnotherPersonNeverTrustsTheProfile(everyNth: Int) {
        var profile = readyProfile()
        for seed in 5..<80 { profile.learn(seed.isMultiple(of: everyNth) ? near(1, seed) : near(0, seed), at: .now) }
        #expect(profile.mean != nil && !profile.isTrusted)
    }

    @Test func aProfileThatStopsMatchingStartsOver() {
        var profile = readyProfile()
        for seed in 5..<15 { profile.learn(near(0, seed), at: .now) }
        for seed in 0..<7 { profile.learn(near(1, seed), at: .now) }
        #expect(profile.mean != nil && !profile.isTrusted)
        let resetAt = Date.now
        profile.learn(near(1, 7), at: resetAt)
        #expect(profile.mean == nil && profile.candidates.isEmpty && profile.createdAt == resetAt)
    }

    @Test func theStoreKeepsTheProfileOutOfBackupsAndForgetsItWhenTheModelChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "VoiceProfile.json")

        let store = VoiceProfileStore(accountDirectory: directory)
        for seed in 0..<5 { try await store.learn(near(0, seed), startedAt: .now) }
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile().mean != nil)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        try await store.forget(learnedBefore: .now.addingTimeInterval(1))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.profile().mean == nil)

        try JSONEncoder().encode(VoiceProfile(modelVersion: "an-older-model", createdAt: .now)).write(to: file)
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile().modelVersion == SpeakerEmbedder.modelVersion)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anUnreadableProfileIsReportedOnceAndLearnedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"modelVersion":"\#(SpeakerEmbedder.modelVersion)"}"#.utf8).write(to: directory.appending(path: "VoiceProfile.json"))

        let store = VoiceProfileStore(accountDirectory: directory)
        await #expect(throws: VoiceFilterError.profileUnreadable) { try await store.profile() }
        #expect(try await store.profile().candidates.isEmpty)
        try await store.learn(near(0, 0), startedAt: .now)
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile().candidates.count == 1)
    }

    @Test func aProfileSavedBeforeHistoryLearningStillLoads() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = #"{"modelVersion":"\#(SpeakerEmbedder.modelVersion)","createdAt":0,"candidates":[],"exemplars":[],"recentMatches":[]}"#
        try Data(saved.utf8).write(to: directory.appending(path: "VoiceProfile.json"))

        let profile = try await VoiceProfileStore(accountDirectory: directory).profile()
        #expect(profile.createdAt == Date(timeIntervalSinceReferenceDate: 0) && profile.historySince == nil)
    }

    @Test func historyTeachesOnceAndOnlyTheProfileItWasReadFor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let window = try #require(try await store.beginHistory())
        let history = (0..<15).map { VoiceHistoryCandidate(embedding: near(0, $0), startedAt: window.end.addingTimeInterval(Double($0 - 100))) }

        let learned = try #require(try await store.learnHistory(history, in: window))
        #expect(learned.isTrusted && learned.learnedSince == window.end.addingTimeInterval(-100))
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile() == learned)
        #expect(try await store.beginHistory() == nil)
        #expect(try await store.learnHistory(history, in: window) == nil)

        try await store.forget(learnedBefore: .now.addingTimeInterval(1))
        #expect(try await store.learnHistory(history, in: window) == nil)
        #expect(try await store.profile().mean == nil)
    }

    @Test func aForgetThatArrivesAfterHistoryLearningStillForgetsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let window = try #require(try await store.beginHistory())
        let history = (0..<5).map { VoiceHistoryCandidate(embedding: near(0, $0), startedAt: window.end.addingTimeInterval(Double($0 - 100))) }
        _ = try #require(try await store.learnHistory(history, in: window))

        try await store.forget(learnedBefore: window.end.addingTimeInterval(-50))
        #expect(try await store.profile().mean == nil)
    }

    @Test func aTrustedProfileSkipsHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        for seed in 0..<15 { try await store.learn(near(0, seed), startedAt: .now) }
        #expect(try await store.profile().isTrusted)

        #expect(try await store.beginHistory() == nil)
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile().historySince != nil)
    }

    @Test func historyFromBeforeAForgetTeachesNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let createdAt = try await store.profile().createdAt
        let forgottenAt = createdAt.addingTimeInterval(-60)
        try await store.forget(learnedBefore: forgottenAt)
        let window = try #require(try await store.beginHistory())
        #expect(window == VoiceHistoryWindow(start: forgottenAt, end: createdAt))
        let history = (0..<5).map { VoiceHistoryCandidate(embedding: near(0, $0), startedAt: forgottenAt.addingTimeInterval(-1)) }

        let learned = try #require(try await store.learnHistory(history, in: window))
        #expect(learned.candidates.isEmpty && learned.mean == nil && learned.learnedSince == createdAt)
        #expect(try await store.beginHistory() == nil)
    }

    @Test func aForgetOnAnotherDeviceClearsTheProfileAndEarlierDictationsTeachNothing() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let started = Date.now
        for seed in 0..<5 { try await store.learn(near(0, seed), startedAt: started) }
        try await store.forget(learnedBefore: started.addingTimeInterval(-60))
        #expect(try await store.profile().mean != nil)

        let forgottenAt = Date.now.addingTimeInterval(1)
        try await store.forget(learnedBefore: forgottenAt)
        #expect(try await store.profile().mean == nil)
        try await store.learn(near(0, 5), startedAt: started)
        #expect(try await store.profile().candidates.isEmpty)
        try await store.learn(near(0, 6), startedAt: forgottenAt.addingTimeInterval(1))
        #expect(try await VoiceProfileStore(accountDirectory: directory).profile().candidates.count == 1)
    }
}

@Suite("Voice history")
struct VoiceHistoryTests {
    @Test func onlyOneVoiceRecordingsInTheWindowTeachOldestFirst() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        func recording(_ names: [String], at offset: TimeInterval, seconds: TimeInterval = 30) throws -> VoiceHistoryRecording {
            var samples: [Float] = []
            for name in names { samples += try SpeakerFixtures.speech(name) + SpeakerFixtures.silence }
            let url = directory.appending(path: "\(UUID().uuidString).wav")
            try PCM16WAVFile.data(pcmData: SpeakerFixtures.pcm16(samples), sampleRate: 16_000).write(to: url)
            return VoiceHistoryRecording(url: url, startedAt: start.addingTimeInterval(offset), finishedAt: start.addingTimeInterval(offset + seconds))
        }
        let oneVoice = ["en-developer-message", "en-short-long-rushed"]
        let unreadable = directory.appending(path: "unreadable.caf")
        try Data("not audio".utf8).write(to: unreadable)
        let older = try recording(oneVoice, at: 100)
        let newer = try recording(oneVoice, at: 300)
        let recordings = [
            newer,
            try recording(["en-teen-note", "en-landlord-email"], at: 200),
            VoiceHistoryRecording(url: unreadable, startedAt: start.addingTimeInterval(400), finishedAt: start.addingTimeInterval(410)),
            older,
            try recording(oneVoice, at: -100),
            try recording(oneVoice, at: 790),
            try recording(oneVoice, at: 500, seconds: 200),
            try recording(oneVoice, at: 600, seconds: 4),
        ]

        let history = try await VoiceHistory.learn(from: recordings, in: VoiceHistoryWindow(start: start, end: start.addingTimeInterval(800)),
                                                   decode: { url in
            let file = try AVAudioFile(forReading: url)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return SpeakerFixtures.pcm16(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
        })
        #expect(history.checked == 4 && history.unreadable == 1)
        #expect(history.candidates.map(\.startedAt) == [older.startedAt, newer.startedAt])
    }
}

