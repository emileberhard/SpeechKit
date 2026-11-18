import Foundation
import SpeechKit

public nonisolated enum VoiceLabelRequest: String, Sendable {
    case watcher
    case transcript
}

public nonisolated struct VoiceCheckResult: Sendable {
    public let text: String
    public let everyone: String
    public let outcome: VoiceFilterOutcome
    public let labelledReplyTime: Duration?
    public let labelRequest: VoiceLabelRequest?
}

nonisolated struct VoiceCheckClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let continuous = Self(now: { .now }, sleep: { try await Task.sleep(until: $0, clock: .continuous) })
}

public actor VoiceCheck {
    public nonisolated static let maximumSamples = VoiceWatch.maximumSamples

    private typealias Fetch = @Sendable (_ pcm16: Data) async throws -> [SpeakerPhrase]

    private struct Delivery: Sendable {
        let result: VoiceCheckResult
        let learns: Bool
    }

    private enum State {
        case capturing
        case checking
        case unflagged(VoiceRecording, fetch: Fetch)
        case decided(VoiceFilterOutcome)
        case failed(any Error)
        case requested
        case waitingForCheck(everyone: String, TranscriptVoices)
        case resolving(everyone: String, TranscriptVoices)
        case committing
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
    private(set) var checking: Task<Void, Never>?
    private var fetching: Task<[SpeakerPhrase], any Error>?
    private var filtering: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var learning: Task<Void, Never>?
    private var continuation: CheckedContinuation<Delivery, any Error>?
    private var requestedAt: ContinuousClock.Instant?
    private var replyTime: Duration?
    private var deliveryDeadline: ContinuousClock.Instant?
    private var labelRequest: VoiceLabelRequest?
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

    public func finish(fetch: @escaping @Sendable (_ pcm16: Data) async throws -> [SpeakerPhrase]) {
        watch.finish()
        guard case .capturing = state else { return }
        guard profile.isTrusted else {
            state = .decided(.undecided)
            return
        }
        state = .checking
        checking = Task { [weak self, watch] in
            let watched: Result<VoiceRecording, any Error>
            do {
                let recording = try await watch.recording
                try Task.checkCancellation()
                watched = .success(recording)
            } catch is CancellationError {
                return
            } catch {
                watched = .failure(error)
            }
            await self?.checked(watched, fetch: fetch)
        }
    }

    public func resolve(everyone: String, linesAreSpeakerTurns: Bool, waitingUpTo budget: Duration) async throws -> VoiceCheckResult {
        try Task.checkCancellation()
        guard store.isCurrent(startedAt: startedAt) else {
            cancel()
            throw CancellationError()
        }
        if case .delivered(let delivered) = state { return delivered }
        let deadline = clock.now().advanced(by: budget)
        let voices = TranscriptVoices(everyone, linesAreSpeakerTurns: linesAreSpeakerTurns)
        if budget <= .zero, case .checking = state {
            checking?.cancel()
            state = .decided(.undecided)
        }
        let delivery: Delivery
        if let immediate = immediateDelivery(everyone: everyone, voices: voices) {
            delivery = immediate
        } else {
            switch state {
            case .checking, .requested: break
            default: throw CancellationError()
            }
            deliveryDeadline = deadline
            delivery = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    if case .requested = state {
                        awaitLabels(everyone: everyone, voices: voices)
                    } else {
                        state = .waitingForCheck(everyone: everyone, voices)
                    }
                    timer = Task { [weak self, clock] in
                        do {
                            try await clock.sleep(deadline)
                            await self?.deadlinePassed()
                        } catch {}
                    }
                }
            } onCancel: {
                Task { await self.cancel() }
            }
        }
        guard !Task.isCancelled, store.isCurrent(startedAt: startedAt) else {
            cancel()
            throw CancellationError()
        }
        if case .cancelled = state { throw CancellationError() }
        return commit(delivery)
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

    private func immediateDelivery(everyone: String, voices: TranscriptVoices) -> Delivery? {
        if voices.marksAnotherSpeaker, case .unflagged(let recording, let fetch) = state {
            request(recording, fetch: fetch, by: .transcript)
        }
        switch state {
        case .capturing:
            watch.finish()
            return delivery(everyone: everyone, text: everyone, outcome: .undecided, learning: voices.teaches)
        case .unflagged:
            return delivery(everyone: everyone, text: everyone, outcome: .notHeard, learning: voices.teaches)
        case .decided(let outcome):
            return delivery(everyone: everyone, text: everyone, outcome: outcome, learning: voices.teaches)
        case .failed(let error):
            report(error)
            return delivery(everyone: everyone, text: everyone, outcome: .failed, learning: false)
        case .checking, .requested, .waitingForCheck, .resolving, .committing, .delivered, .cancelled:
            return nil
        }
    }

    private func awaitLabels(everyone: String, voices: TranscriptVoices) {
        state = .resolving(everyone: everyone, voices)
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
    }

    private func continueWaiting(everyone: String, voices: TranscriptVoices) {
        if let delivery = immediateDelivery(everyone: everyone, voices: voices) {
            complete(delivery)
        } else {
            awaitLabels(everyone: everyone, voices: voices)
        }
    }

    private func deadlinePassed() {
        switch state {
        case .waitingForCheck(let everyone, let voices):
            guard store.isCurrent(startedAt: startedAt) else { return cancel() }
            checking?.cancel()
            complete(delivery(everyone: everyone, text: everyone, outcome: .undecided, learning: voices.teaches))
        case .resolving:
            filtered(.failure(VoiceFilterError.deadlineExceeded))
        default:
            break
        }
    }

    private func complete(_ delivery: Delivery) {
        timer?.cancel()
        state = .committing
        continuation?.resume(returning: delivery)
        continuation = nil
    }

    private func checked(_ watched: Result<VoiceRecording, any Error>, fetch: @escaping Fetch) {
        let waiting: (everyone: String, voices: TranscriptVoices)?
        switch state {
        case .checking: waiting = nil
        case .waitingForCheck(let everyone, let voices): waiting = (everyone, voices)
        default: return
        }
        guard store.isCurrent(startedAt: startedAt) else {
            if waiting != nil { cancel() }
            return
        }
        if waiting != nil, let deliveryDeadline, clock.now() >= deliveryDeadline {
            return deadlinePassed()
        }
        switch watched {
        case .failure(let error):
            state = .failed(error)
        case .success(let recording) where !recording.isComplete:
            state = .decided(.tooLong)
        case .success(let recording) where recording.requestsLabels:
            request(recording, fetch: fetch, by: .watcher)
        case .success(let recording):
            state = .unflagged(recording, fetch: fetch)
        }
        if let waiting { continueWaiting(everyone: waiting.everyone, voices: waiting.voices) }
    }

    private func request(_ recording: VoiceRecording, fetch: @escaping Fetch, by labelRequest: VoiceLabelRequest) {
        self.recording = recording
        self.labelRequest = labelRequest
        state = .requested
        requestedAt = clock.now()
        let pcm = recording.audio.pcm
        fetching = Task { [weak self, clock] in
            do {
                let pcm16 = await pcm.data()
                try Task.checkCancellation()
                let phrases = try await fetch(pcm16)
                await self?.receivedReply(at: clock.now())
                return phrases
            } catch {
                await self?.receivedReply(at: clock.now())
                throw error
            }
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
        guard case .resolving(let everyone, let voices) = state else { return }
        guard store.isCurrent(startedAt: startedAt) else { return cancel() }
        let audio = recording!.audio
        let profile = profile.trustedMean!
        filtering = Task { [weak self] in
            do {
                let filtered = try await VoiceFilter.apply(phrases, everyone: everyone, marksAnotherSpeaker: voices.marksAnotherSpeaker,
                                                           audio: audio, profile: profile)
                await self?.filtered(.success(filtered))
            } catch {
                await self?.filtered(.failure(error))
            }
        }
    }

    private func filtered(_ filtered: Result<(text: String, outcome: VoiceFilterOutcome), any Error>) {
        guard case .resolving(let everyone, let voices) = state else { return }
        guard store.isCurrent(startedAt: startedAt) else { return cancel() }
        let delivery: Delivery
        if let deadline = deliveryDeadline, clock.now() >= deadline {
            report(VoiceFilterError.deadlineExceeded)
            delivery = self.delivery(everyone: everyone, text: everyone, outcome: .failed, learning: false)
        } else {
            switch filtered {
            case .success(let filtered):
                delivery = self.delivery(everyone: everyone, text: filtered.text, outcome: filtered.outcome,
                                         learning: voices.teaches && filtered.outcome.labelCount <= 1 && filtered.outcome.droppedCount == 0)
            case .failure(let error):
                report(error)
                delivery = self.delivery(everyone: everyone, text: everyone, outcome: .failed, learning: false)
            }
        }
        fetching?.cancel()
        filtering?.cancel()
        complete(delivery)
    }

    private func report(_ error: any Error) {
        onFailure(.filter, error)
    }

    private func delivery(everyone: String, text: String, outcome: VoiceFilterOutcome, learning learns: Bool) -> Delivery {
        Delivery(result: VoiceCheckResult(text: text, everyone: everyone, outcome: outcome,
                                          labelledReplyTime: requestedAt.map { replyTime ?? $0.duration(to: clock.now()) },
                                          labelRequest: labelRequest),
                 learns: learns)
    }

    private func commit(_ delivery: Delivery) -> VoiceCheckResult {
        let result = delivery.result
        recording = nil
        state = .delivered(result)
        if delivery.learns {
            learning = Task { [self] in
                defer { learning = nil }
                do {
                    let recording = try await watch.recording
                    guard let candidate = try await recording.learningCandidate() else { return }
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

    @concurrent public static func filter(pcm16: Data, phrases: [SpeakerPhrase]?, everyone: String, linesAreSpeakerTurns: Bool,
                                         profile: VoiceProfile, store: VoiceProfileStore, startedAt: Date,
                                         onFailure: @Sendable (VoiceFilterStage, any Error) -> Void) async -> VoiceCheckResult {
        func unfiltered(_ outcome: VoiceFilterOutcome) -> VoiceCheckResult {
            VoiceCheckResult(text: everyone, everyone: everyone, outcome: outcome, labelledReplyTime: nil, labelRequest: nil)
        }
        guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else { return unfiltered(.undecided) }
        guard pcm16.count / 2 <= VoiceWatch.maximumSamples else { return unfiltered(.tooLong) }
        guard let reference = profile.trustedMean else { return unfiltered(.undecided) }
        do {
            guard let phrases else { throw VoiceFilterError.voicesUnavailable }
            let audio = SpeakerAudio(embedder: try SpeakerEmbedder(modelURL: SpeakerEmbedder.requireModelURL()), pcm: PCM16Audio(pcm16))
            let voices = TranscriptVoices(everyone, linesAreSpeakerTurns: linesAreSpeakerTurns)
            let result = try await VoiceFilter.apply(phrases, everyone: everyone, marksAnotherSpeaker: voices.marksAnotherSpeaker,
                                                     audio: audio, profile: reference)
            guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else { return unfiltered(.undecided) }
            return VoiceCheckResult(text: result.text, everyone: everyone, outcome: result.outcome, labelledReplyTime: nil,
                                    labelRequest: nil)
        } catch {
            guard store.isCurrent(startedAt: startedAt), !Task.isCancelled else { return unfiltered(.undecided) }
            onFailure(.filter, error)
            return unfiltered(.failed)
        }
    }
}
