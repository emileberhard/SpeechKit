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

@Suite("Voice check")
struct VoiceCheckTests {
    private func trustedProfile() -> VoiceProfile {
        var profile = VoiceProfile(modelVersion: SpeakerEmbedder.modelVersion, createdAt: .now)
        let embedding = SpeakerEmbedding(normalizing: [1] + [Float](repeating: 0, count: 255))
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
        let check = try VoiceCheck(profile: trustedProfile(), store: store, startedAt: .now, onFailure: { _, failure in
            if let error = failure.underlying as? VoiceFilterError { failures.withLock { $0.append(error) } }
        }, clock: clock)
        check.append(try mixedAudio())
        await check.finish {
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
        let check = try VoiceCheck(profile: trustedProfile(), store: store, startedAt: .now,
                                  onFailure: { _, _ in failures.withLock { $0 += 1 } },
                                  clock: VoiceCheckClock(now: { .now }, sleep: { _ in
            await timerStarted.open()
            await release.wait()
        }))
        check.append(try mixedAudio())
        await check.finish {
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
        await check.finish { throw VoiceFilterError.voicesUnavailable }
        let result = try await check.resolve(everyone: "Everyone.", waitingUpTo: .seconds(2))
        await check.cancel()
        while try await store.profile().candidates.isEmpty { await Task.yield() }
        #expect(result.text == "Everyone." && result.outcome.path == .undecided)
        #expect(try await store.profile().candidates.count == 1)
        #expect(failures.withLock { $0 } == 0)
    }

}
