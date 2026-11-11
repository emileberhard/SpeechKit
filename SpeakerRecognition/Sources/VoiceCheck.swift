import Foundation
import SpeechKit

public nonisolated struct VoiceCheckResult: Sendable {
    public let text: String
    public let everyone: String
    public let outcome: VoiceFilterOutcome
    public let labelledReplyTime: Duration?
}

nonisolated struct VoiceCheckClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    static let continuous = Self(now: { .now }, sleep: { try await Task.sleep(for: $0) })
}

public actor VoiceCheck {
    public nonisolated static let maximumSamples = VoiceWatch.maximumSamples

    private enum State {
        case capturing
        case checking
        case decided(VoiceFilterOutcome)
        case failed(any Error)
        case requested
        case resolving
        case delivered(VoiceCheckResult)
        case cancelled
    }

    private nonisolated let watch: VoiceWatch
    private let profile: VoiceProfile
    private let store: VoiceProfileStore
    private let startedAt: Date
    private let onFailure: @Sendable (VoiceFilterStage, any Error) -> Void
    private let clock: VoiceCheckClock
    private var state = State.capturing
    private var checking: Task<Void, Never>?
    private var fetching: Task<[SpeakerPhrase], any Error>?
    private var filtering: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var learning: Task<Void, Never>?
    private var continuation: CheckedContinuation<VoiceCheckResult, any Error>?
    private var requestedAt: ContinuousClock.Instant?
    private var replyTime: Duration?
    private var deliveryDeadline: ContinuousClock.Instant?
    private var everyone = ""
    private var recording: VoiceRecording?

    public init(profile: VoiceProfile, store: VoiceProfileStore, startedAt: Date,
                onFailure: @escaping @Sendable (VoiceFilterStage, any Error) -> Void) throws {
        self.init(profile: profile, store: store, startedAt: startedAt, onFailure: onFailure,
                  watch: VoiceWatch(modelURL: try SpeakerEmbedder.requireModelURL(), profile: profile.trustedMean), clock: .continuous)
    }

    init(profile: VoiceProfile, store: VoiceProfileStore, startedAt: Date,
         onFailure: @escaping @Sendable (VoiceFilterStage, any Error) -> Void, watch: VoiceWatch, clock: VoiceCheckClock) {
        self.profile = profile
        self.store = store
        self.startedAt = startedAt
        self.onFailure = onFailure
        self.clock = clock
        self.watch = watch
    }

    deinit {
        checking?.cancel()
        fetching?.cancel()
        filtering?.cancel()
        timer?.cancel()
        learning?.cancel()
    }

    public nonisolated func append(_ pcm16: Data) { watch.append(pcm16) }

    public func finish(fetch: @escaping @Sendable () async throws -> [SpeakerPhrase]) {
        watch.finish()
        guard case .capturing = state else { return }
        guard profile.isTrusted else {
            state = .decided(.undecided)
            return
        }
        state = .checking
        checking = Task { [weak self, watch] in
            do {
                let recording = try await watch.recording
                try Task.checkCancellation()
                await self?.checked(recording, fetch: fetch)
            } catch is CancellationError {
            } catch {
                await self?.checkFailed(error)
            }
        }
    }

    public func resolve(everyone: String, waitingUpTo budget: Duration) async throws -> VoiceCheckResult {
        try Task.checkCancellation()
        guard store.isCurrent(startedAt: startedAt) else {
            cancel()
            throw CancellationError()
        }
        switch state {
        case .cancelled, .resolving: throw CancellationError()
        case .delivered(let result): return result
        case .capturing:
            watch.finish()
            return deliver(everyone: everyone, text: everyone, outcome: .undecided, learns: true)
        case .checking:
            checking?.cancel()
            return deliver(everyone: everyone, text: everyone, outcome: .undecided, learns: true)
        case .decided(let outcome):
            return deliver(everyone: everyone, text: everyone, outcome: outcome, learns: true)
        case .failed(let error):
            report(error)
            return deliver(everyone: everyone, text: everyone, outcome: .failed, learns: false)
        case .requested:
            self.everyone = everyone
            deliveryDeadline = clock.now().advanced(by: budget)
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    state = .resolving
                    let fetch = fetching!
                    filtering = Task { [weak self] in
                        do {
                            let phrases = try await fetch.value
                            try Task.checkCancellation()
                            await self?.receivedPhrases(phrases)
                        } catch {
                            await self?.filtered(.failure(error))
                        }
                    }
                    timer = Task { [weak self, clock, budget] in
                        do {
                            try await clock.sleep(budget)
                            await self?.filtered(.failure(VoiceFilterError.deadlineExceeded))
                        } catch {}
                    }
                }
            } onCancel: {
                Task { await self.cancel() }
            }
            try Task.checkCancellation()
            return result
        }
    }

    public func cancel() {
        if case .delivered = state { return }
        state = .cancelled
        recording = nil
        checking?.cancel()
        fetching?.cancel()
        filtering?.cancel()
        timer?.cancel()
        learning?.cancel()
        watch.cancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func checked(_ recording: VoiceRecording, fetch: @escaping @Sendable () async throws -> [SpeakerPhrase]) {
        guard case .checking = state, store.isCurrent(startedAt: startedAt) else { return }
        if !recording.isComplete {
            state = .decided(.tooLong)
        } else if recording.requestsLabels {
            self.recording = recording
            state = .requested
            requestedAt = clock.now()
            fetching = Task { [weak self, clock] in
                do {
                    let phrases = try await fetch()
                    await self?.receivedReply(at: clock.now())
                    return phrases
                } catch {
                    await self?.receivedReply(at: clock.now())
                    throw error
                }
            }
        } else {
            state = .decided(.notHeard)
        }
    }

    private func receivedReply(at instant: ContinuousClock.Instant) {
        guard let requestedAt else { return }
        switch state {
        case .requested, .resolving: replyTime = requestedAt.duration(to: instant)
        default: break
        }
    }

    private func receivedPhrases(_ phrases: [SpeakerPhrase]) {
        guard case .resolving = state else { return }
        guard store.isCurrent(startedAt: startedAt) else { return cancel() }
        let audio = recording!.audio
        let profile = profile.trustedMean!
        let everyone = everyone
        filtering = Task { [weak self] in
            do {
                let filtered = try await VoiceFilter.apply(phrases, everyone: everyone, audio: audio, profile: profile)
                await self?.filtered(.success(filtered))
            } catch {
                await self?.filtered(.failure(error))
            }
        }
    }

    private func checkFailed(_ error: any Error) {
        guard case .checking = state else { return }
        state = .failed(error)
    }

    private func filtered(_ filtered: Result<(text: String, outcome: VoiceFilterOutcome), any Error>) {
        guard case .resolving = state else { return }
        guard store.isCurrent(startedAt: startedAt) else { return cancel() }
        let result: VoiceCheckResult
        if let deadline = deliveryDeadline, clock.now() >= deadline {
            report(VoiceFilterError.deadlineExceeded)
            result = deliver(everyone: everyone, text: everyone, outcome: .failed, learns: false)
        } else {
            switch filtered {
            case .success(let filtered):
                result = deliver(everyone: everyone, text: filtered.text, outcome: filtered.outcome, learns: true)
            case .failure(let error):
                report(error)
                result = deliver(everyone: everyone, text: everyone, outcome: .failed, learns: false)
            }
        }
        timer?.cancel()
        fetching?.cancel()
        filtering?.cancel()
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func report(_ error: any Error) {
        onFailure(.filter, error)
    }

    private func deliver(everyone: String, text: String, outcome: VoiceFilterOutcome, learns: Bool) -> VoiceCheckResult {
        let result = VoiceCheckResult(text: text, everyone: everyone, outcome: outcome,
                                     labelledReplyTime: requestedAt.map { replyTime ?? $0.duration(to: clock.now()) })
        recording = nil
        state = .delivered(result)
        if learns {
            learning = Task { [self] in
                defer { learning = nil }
                do {
                    guard let candidate = try await watch.recording.learningCandidate() else { return }
                    try Task.checkCancellation()
                    try await store.learn(candidate, startedAt: startedAt)
                } catch is CancellationError {
                } catch {
                    guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else { return }
                    onFailure(.learning, error)
                }
            }
        }
        return result
    }

    @concurrent public static func filter(pcm16: Data, phrases: [SpeakerPhrase]?, everyone: String, profile: VoiceProfile,
                                         store: VoiceProfileStore, startedAt: Date,
                                         onFailure: @Sendable (VoiceFilterStage, any Error) -> Void) async -> VoiceCheckResult {
        guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else {
            return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .undecided, labelledReplyTime: nil)
        }
        guard pcm16.count / 2 <= VoiceWatch.maximumSamples else {
            return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .tooLong, labelledReplyTime: nil)
        }
        guard let reference = profile.trustedMean else {
            return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .undecided, labelledReplyTime: nil)
        }
        do {
            guard let phrases else { throw VoiceFilterError.voicesUnavailable }
            let audio = SpeakerAudio(embedder: try SpeakerEmbedder(modelURL: SpeakerEmbedder.requireModelURL()), pcm: PCM16Audio(pcm16))
            let result = try await VoiceFilter.apply(phrases, everyone: everyone, audio: audio, profile: reference)
            guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else {
                return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .undecided, labelledReplyTime: nil)
            }
            return VoiceCheckResult(text: result.text, everyone: everyone, outcome: result.outcome, labelledReplyTime: nil)
        } catch {
            guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else {
                return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .undecided, labelledReplyTime: nil)
            }
            onFailure(.filter, error)
            return VoiceCheckResult(text: everyone, everyone: everyone, outcome: .failed, labelledReplyTime: nil)
        }
    }
}
