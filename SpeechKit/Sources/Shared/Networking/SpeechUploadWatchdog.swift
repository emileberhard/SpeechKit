import Dispatch
import Foundation
import Synchronization

final class SpeechUploadWatchdog: Sendable {
    private struct State {
        var timer: (any DispatchSourceTimer)?
        var offered: Int64 = 0
        var sent: Int64 = 0
        var finished = false
        var lastProgress = ContinuousClock.now
        var responseStarted: ContinuousClock.Instant?
        var failure: (any Error)?
        var stopped = false
    }

    private let state = Mutex(State())
    private let stallTimeout: Duration
    private let responseTimeout: Duration?
    private let failed: @Sendable (any Error) -> Void

    init(stallTimeout: Duration, responseTimeout: Duration?, failed: @escaping @Sendable (any Error) -> Void) {
        precondition(stallTimeout > .zero && (responseTimeout.map { $0 > .zero } ?? true))
        self.stallTimeout = stallTimeout
        self.responseTimeout = responseTimeout
        self.failed = failed
    }

    deinit { stop() }

    func start() {
        state.withLock { state in
            guard !state.stopped, state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.setEventHandler { [weak self] in self?.check() }
            state.timer = timer
            state.lastProgress = .now
            schedule(&state)
            timer.resume()
        }
    }

    func offer(_ count: Int) {
        state.withLock { state in
            if state.offered <= state.sent && !state.finished { state.lastProgress = .now }
            state.offered += Int64(count)
            schedule(&state)
        }
    }

    func finishBody() {
        state.withLock { state in
            state.finished = true
            if state.sent >= state.offered { state.responseStarted = .now }
            schedule(&state)
        }
    }

    func sent(_ total: Int64) {
        state.withLock { state in
            guard total > state.sent else { return }
            state.sent = total
            state.lastProgress = .now
            if state.finished && total >= state.offered && state.responseStarted == nil {
                state.responseStarted = .now
            }
            schedule(&state)
        }
    }

    func received() {
        state.withLock { state in
            state.lastProgress = .now
            schedule(&state)
        }
    }

    var failure: (any Error)? { state.withLock { $0.failure } }

    func stop() {
        state.withLock { state in
            state.stopped = true
            state.timer?.cancel()
            state.timer = nil
        }
    }

    private func deadline(_ state: State) -> ContinuousClock.Instant? {
        if let responseStarted = state.responseStarted, let responseTimeout {
            return responseStarted.advanced(by: responseTimeout)
        }
        if state.offered > state.sent || state.finished {
            return state.lastProgress.advanced(by: stallTimeout)
        }
        return nil
    }

    private func schedule(_ state: inout State) {
        guard !state.stopped else { return }
        guard let deadline = deadline(state) else {
            state.timer?.schedule(deadline: .distantFuture)
            return
        }
        let seconds = max(0, Double(ContinuousClock.now.duration(to: deadline) / .seconds(1)))
        state.timer?.schedule(deadline: .now() + seconds)
    }

    private func check() {
        let error: (any Error)? = state.withLock { state in
            guard !state.stopped, let deadline = deadline(state) else { return nil }
            guard ContinuousClock.now >= deadline else { schedule(&state); return nil }
            let error: any Error = state.responseStarted != nil && responseTimeout != nil
                ? URLError(.timedOut) : ProgressiveTranscriptionError.stalled
            state.failure = error
            state.stopped = true
            state.timer?.cancel()
            state.timer = nil
            return error
        }
        if let error { failed(error) }
    }
}
