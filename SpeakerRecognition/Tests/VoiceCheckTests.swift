import Foundation
import os
import SpeechKit
import Testing
@testable import SpeakerRecognition

private actor Signal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@Suite("Voice check", .serialized)
struct VoiceCheckTests {
    private func trustedProfile() async throws -> VoiceProfile {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        let embedding = try await SpeakerFixtures.embedder().embedding(of: SpeakerFixtures.speech("en-teen-note"))
        for _ in 0..<15 { profile.learn(embedding, at: .now) }
        return profile
    }

    private func mixedAudio() throws -> Data {
        var samples: [Float] = []
        for name in ["en-teen-note", "en-landlord-email"] {
            samples += try SpeakerFixtures.speech(name) + SpeakerFixtures.silence
        }
        return SpeakerFixtures.pcm16(samples)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowReplyWithinTheCallerBudgetIsKeptAndTimed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = Signal(), timerStarted = Signal(), releaseFetch = Signal(), releaseTimer = Signal()
        let now = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let clock = VoiceCheckClock(now: { now.withLock { $0 } }, sleep: { _ in
            await timerStarted.open()
            await releaseTimer.wait()
        })
        let profile = try await trustedProfile()
        let check = VoiceCheck(profile: profile, store: VoiceProfileStore(accountDirectory: directory), startedAt: .now,
                                  onFailure: { _, _ in failures.withLock { $0 += 1 } },
                                  watch: VoiceWatch(modelURL: try SpeakerFixtures.modelURL(), profile: profile.trustedMean), clock: clock)
        check.append(try mixedAudio())
        await check.finish { _ in
            await requested.open()
            await releaseFetch.wait()
            return []
        }
        await requested.wait()
        let delivery = Task { try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(3)) }
        await timerStarted.wait()
        now.withLock { $0 = $0.advanced(by: .milliseconds(2_200)) }
        await releaseFetch.open()
        let result = try await delivery.value
        #expect(result.text == "Everyone." && result.outcome.path == .keptEveryone)
        #expect(result.labelledReplyTime == .milliseconds(2_200))
        #expect(failures.withLock { $0 } == 0)
        await releaseTimer.open()
        await check.cancel()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [4.1, 5.0], [1, 2])
    func labelledMixedSpeechNeverTeachesTheProfile(ownSeconds: Double, labelCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = try SpeakerFixtures.continuousSpeech("en-teen-note")
        let other = try SpeakerFixtures.continuousSpeech("en-landlord-email")
        let embedding = try await SpeakerFixtures.embedder().embedding(of: own)
        let store = VoiceProfileStore(accountDirectory: directory)
        for _ in 0..<15 { try await store.learn(embedding, startedAt: .now) }
        let before = try await store.profile()
        #expect(before.isTrusted && !before.isFrozen)
        let samples = Array(other.prefix(64_000)) + Array(own.prefix(Int(ownSeconds * 16_000)))
        let split = 4_000
        let end = samples.count * 1_000 / 16_000
        let phrases = labelCount == 1 ? [
            SpeakerPhrase(speaker: 0, text: "First. Second.", words: [.zero ..< .milliseconds(end)]),
        ] : [
            SpeakerPhrase(speaker: 0, text: "First.", words: [.zero ..< .milliseconds(split)]),
            SpeakerPhrase(speaker: 1, text: "Second.", words: [.milliseconds(split) ..< .milliseconds(end)]),
        ]
        let requested = Signal()
        var check: VoiceCheck? = try VoiceCheck(profile: before, store: store, startedAt: .now,
                                               onFailure: { _, _ in Issue.record("Unexpected failure") })
        weak let released = check
        check!.append(SpeakerFixtures.pcm16(samples))
        await check!.finish { _ in
            await requested.open()
            return phrases
        }
        await requested.wait()
        let result = try await check!.resolve(everyone: "First. Second.", waitingUpTo: .seconds(5))
        #expect(result.outcome.labelCount == labelCount)
        if labelCount == 1 { #expect(result.outcome.droppedCount == 0) }
        await check!.cancel()
        check = nil
        while released != nil { await Task.yield() }
        #expect(try await store.profile() == before)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringStoredWatcherFailureThrows() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = try await trustedProfile()
        let watch = VoiceWatch(modelURL: directory.appendingPathComponent("missing.mlmodelc"), profile: profile.trustedMean)
        let caller = OSAllocatedUnfairLock<Task<VoiceCheckResult, any Error>?>(initialState: nil)
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let check = VoiceCheck(profile: profile, store: VoiceProfileStore(accountDirectory: directory), startedAt: .now,
                               onFailure: { _, _ in
            failures.withLock { $0 += 1 }
            caller.withLock { $0 }?.cancel()
        }, watch: watch, clock: .continuous)
        await check.finish { _ in [] }
        await check.checking?.value
        let start = Signal()
        let resolving = Task {
            await start.wait()
            return try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(2))
        }
        caller.withLock { $0 = resolving }
        await start.open()
        await #expect(throws: CancellationError.self) { try await resolving.value }
        #expect(failures.withLock { $0 } == 1)
        await check.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func theDeadlineDoesNotJoinAnUncooperativeFetchAndLateLabelsCannotChangeDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = Signal(), timerStarted = Signal(), fireTimer = Signal(), releaseFetch = Signal()
        let now = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let failures = OSAllocatedUnfairLock<[VoiceFilterError]>(initialState: [])
        let store = VoiceProfileStore(accountDirectory: directory)
        let clock = VoiceCheckClock(now: { now.withLock { $0 } }, sleep: { _ in
            await timerStarted.open()
            await fireTimer.wait()
        })
        let profile = try await trustedProfile()
        let check = VoiceCheck(profile: profile, store: store, startedAt: .now, onFailure: { _, failure in
            if let error = failure as? VoiceFilterError { failures.withLock { $0.append(error) } }
        }, watch: VoiceWatch(modelURL: try SpeakerFixtures.modelURL(), profile: profile.trustedMean), clock: clock)
        check.append(try mixedAudio())
        await check.finish { _ in
            await requested.open()
            await releaseFetch.wait()
            return [SpeakerPhrase(speaker: 0, text: "Late.", words: [])]
        }
        await requested.wait()
        let resultTask = Task { try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(2)) }
        await timerStarted.wait()
        now.withLock { $0 = $0.advanced(by: .seconds(2)) }
        await fireTimer.open()
        let result = try await resultTask.value
        #expect(result.text == "Everyone." && result.everyone == "Everyone.")
        #expect(result.outcome.path == .failed && result.labelledReplyTime == .seconds(2))
        #expect(failures.withLock { $0 } == [.deadlineExceeded])
        await releaseFetch.open()
        let repeated = try await check.resolve(everyone: "Replacement.", waitingUpTo: .seconds(2))
        #expect(repeated.text == result.text && repeated.labelledReplyTime == result.labelledReplyTime)
        await check.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationSilencesALateReplyAndRetirementBlocksLearning() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = Signal(), timerStarted = Signal(), release = Signal()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let store = VoiceProfileStore(accountDirectory: directory)
        let profile = try await trustedProfile()
        let check = VoiceCheck(profile: profile, store: store, startedAt: .now,
                                  onFailure: { _, _ in failures.withLock { $0 += 1 } },
                                  watch: VoiceWatch(modelURL: try SpeakerFixtures.modelURL(), profile: profile.trustedMean),
                                  clock: VoiceCheckClock(now: { .now }, sleep: { _ in
            await timerStarted.open()
            await release.wait()
        }))
        check.append(try mixedAudio())
        await check.finish { _ in
            await requested.open()
            await release.wait()
            throw VoiceFilterError.voicesUnavailable
        }
        await requested.wait()
        let result = Task { try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(2)) }
        await timerStarted.wait()
        await check.cancel()
        await #expect(throws: CancellationError.self) { try await result.value }
        await release.open()
        #expect(failures.withLock { $0 } == 0)
        store.retire()
        try await store.learn(SpeakerEmbedding(normalizing: [1, 0]), startedAt: .now)
        #expect(try await store.profile().candidates.isEmpty)
    }
    @Test(.timeLimit(.minutes(1)))
    func cancellingAfterDeliveryStillLearnsTheRecording() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let failures = OSAllocatedUnfairLock(initialState: 0)
        let check = try VoiceCheck(profile: await store.profile(), store: store, startedAt: .now,
                                  onFailure: { _, _ in failures.withLock { $0 += 1 } })
        check.append(SpeakerFixtures.pcm16(try SpeakerFixtures.speech("en-developer-message")))
        await check.finish { _ in throw VoiceFilterError.voicesUnavailable }
        let result = try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(2))
        await check.cancel()
        while try await store.profile().candidates.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result.text == "Everyone." && result.outcome.path == .undecided)
        #expect(try await store.profile().candidates.count == 1)
        #expect(failures.withLock { $0 } == 0)
    }

    @Test(arguments: [[], [SpeakerPhrase(speaker: 0, text: "Relabelled.", words: [.zero ..< .milliseconds(100)])]])
    func batchDoubtPreservesTheCallersOriginal(phrases: [SpeakerPhrase]) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let result = await VoiceCheck.filter(pcm16: Data(repeating: 0, count: 32_000), phrases: phrases,
                                            everyone: "Original transcript.", profile: try await trustedProfile(), store: store, startedAt: .now,
                                            onFailure: { _, _ in Issue.record("Unexpected failure") })
        #expect(result.text == "Original transcript." && result.everyone == "Original transcript.")
        #expect(result.outcome.path == .keptEveryone && result.outcome.droppedCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func filteringThroughThePublicCheckDropsAnotherSyntheticVoice() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let own = try SpeakerFixtures.speech("en-short-long-rushed")
        let other = try SpeakerFixtures.speech("en-teen-note")
        let embedder = try SpeakerFixtures.embedder()
        let embedding = try await embedder.embedding(of: own)
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        for _ in 0..<15 { profile.learn(embedding, at: .now) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let check = try VoiceCheck(profile: profile, store: store, startedAt: .now,
                                  onFailure: { _, _ in Issue.record("Unexpected failure") })
        let requested = Signal()
        let pcm16 = SpeakerFixtures.pcm16(own + SpeakerFixtures.silence + other + SpeakerFixtures.silence)
        for offset in stride(from: 0, to: pcm16.count, by: 3_200) {
            check.append(pcm16.subdata(in: offset..<min(offset + 3_200, pcm16.count)))
        }
        let otherStart = Duration.seconds(Double(own.count + 16_000) / 16_000)
        let phrases = [
            SpeakerPhrase(speaker: 0, text: "Mine.", words: [.zero ..< .seconds(Double(own.count) / 16_000)]),
            SpeakerPhrase(speaker: 1, text: "Other.", words: [otherStart ..< otherStart + .seconds(Double(other.count) / 16_000)]),
        ]
        await check.finish { admittedPCM in
            #expect(admittedPCM == pcm16)
            await requested.open()
            return phrases
        }
        await requested.wait()
        let result = try await check.resolve(everyone: "Mine. Other.", waitingUpTo: .seconds(5))
        #expect(result.text == "Mine." && result.everyone == "Mine. Other.")
        #expect(result.outcome.path == .filtered && result.outcome.droppedCount == 1)
        await check.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func anOverLimitRecordingNeverFetchesLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        let check = try VoiceCheck(profile: await trustedProfile(), store: store, startedAt: .now,
                                  onFailure: { _, _ in Issue.record("Unexpected failure") })
        check.append(Data(repeating: 0, count: (VoiceCheck.maximumSamples + 1) * 2))
        await check.finish { _ in
            Issue.record("An over-limit recording must not fetch labels")
            return []
        }
        await check.checking?.value
        let result = try await check.resolve(everyone: "Original.", waitingUpTo: .seconds(2))
        #expect(result.text == "Original." && result.outcome.path == .tooLong)
        await check.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func resolvingWithoutFinishClosesTheWatcherAndReleasesTheCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceProfileStore(accountDirectory: directory)
        var check: VoiceCheck? = try VoiceCheck(profile: await store.profile(), store: store, startedAt: .now,
                                               onFailure: { _, _ in Issue.record("Unexpected failure") })
        weak let released = check
        check!.append(SpeakerFixtures.pcm16(try SpeakerFixtures.speech("en-developer-message")))
        let result = try await check!.resolve(everyone: "Original.", waitingUpTo: .seconds(2))
        check = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while released != nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(result.text == "Original." && released == nil)
        #expect(try await store.profile().candidates.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutReleasesTheModelWhileAnUncooperativeFetchRemainsSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = Signal(), timerStarted = Signal(), fireTimer = Signal(), releaseFetch = Signal()
        let now = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let store = VoiceProfileStore(accountDirectory: directory)
        let clock = VoiceCheckClock(now: { now.withLock { $0 } }, sleep: { _ in
            await timerStarted.open()
            await fireTimer.wait()
        })
        func makeCheck() async throws -> (VoiceCheck, ModelLifetime) {
            let profile = try await trustedProfile()
            let watch = VoiceWatch(modelURL: try SpeakerFixtures.modelURL(), profile: profile.trustedMean)
            let check = VoiceCheck(profile: profile, store: store, startedAt: .now, onFailure: { _, _ in }, watch: watch, clock: clock)
            check.append(try mixedAudio())
            await check.finish { _ in
                await requested.open()
                await releaseFetch.wait()
                return []
            }
            return (check, ModelLifetime(model: try await watch.recording.audio.embedder))
        }
        var (check, model) = try await makeCheck() as (VoiceCheck?, ModelLifetime)
        await requested.wait()
        let resultTask = Task { [check = check!] in try await check.resolve(everyone: "Original.", waitingUpTo: .seconds(2)) }
        await timerStarted.wait()
        now.withLock { $0 = $0.advanced(by: .seconds(2)) }
        await fireTimer.open()
        let result = try await resultTask.value
        check = nil
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await model.isReleased) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await model.isReleased)
        #expect(result.text == "Original." && result.outcome.path == .failed)
        await releaseFetch.open()
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerCancelledAtTheDeliveryBoundaryReceivesCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requested = Signal(), timerStarted = Signal(), fireTimer = Signal(), releaseFetch = Signal()
        let now = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let caller = OSAllocatedUnfairLock<Task<VoiceCheckResult, any Error>?>(initialState: nil)
        let store = VoiceProfileStore(accountDirectory: directory)
        let profile = try await trustedProfile()
        let check = VoiceCheck(profile: profile, store: store, startedAt: .now,
                               onFailure: { _, _ in caller.withLock { $0 }?.cancel() },
                               watch: VoiceWatch(modelURL: try SpeakerFixtures.modelURL(), profile: profile.trustedMean),
                               clock: VoiceCheckClock(now: { now.withLock { $0 } }, sleep: { _ in
            await timerStarted.open()
            await fireTimer.wait()
        }))
        check.append(try mixedAudio())
        await check.finish { _ in
            await requested.open()
            await releaseFetch.wait()
            return []
        }
        await requested.wait()
        let resultTask = Task { try await check.resolve(everyone: "Original.", waitingUpTo: .seconds(2)) }
        caller.withLock { $0 = resultTask }
        await timerStarted.wait()
        now.withLock { $0 = $0.advanced(by: .seconds(2)) }
        await fireTimer.open()
        await #expect(throws: CancellationError.self) { try await resultTask.value }
        await releaseFetch.open()
    }

}

private actor ModelLifetime {
    private weak var model: SpeakerEmbedder?

    init(model: SpeakerEmbedder) { self.model = model }

    var isReleased: Bool { model == nil }
}
