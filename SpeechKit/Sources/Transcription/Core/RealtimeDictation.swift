import Foundation
import os

public final class RealtimeDictation: Sendable {
    public let sampleRate: Int
    private let input: RealtimeDictationInput
    private let transcription: Task<String, any Error>

    public init(session: any RealtimeTranscriptionSession) {
        let (signals, signal) = AsyncStream<RealtimeDictationSignal>.makeStream()
        let bytesPerSecond = session.sampleRate * MemoryLayout<Int16>.size
        let input = RealtimeDictationInput(
            bytesPerSecond: bytesPerSecond,
            maximumPendingByteCount: RealtimeDictationInput.maximumPendingSeconds * bytesPerSecond,
            signal: signal
        )
        sampleRate = session.sampleRate
        self.input = input
        transcription = Task {
            try await RealtimeDictationRun(session: session, input: input, signal: signal).transcribe(signals)
        }
    }

    deinit {
        transcription.cancel()
    }

    public func append(_ pcm16: Data) {
        input.append(pcm16)
    }

    public func finish() async throws -> String {
        input.finish()
        return try await withTaskCancellationHandler {
            try await transcription.value
        } onCancel: { [transcription] in
            transcription.cancel()
        }
    }

    public func cancel() async {
        transcription.cancel()
        _ = await transcription.result
    }
}

public enum RealtimeDictationError: Error, Sendable {
    case connectionFailed(any Error)
    case streamFailed(any Error)
    case commitFailed(any Error)
    case streamEnded
    case finalizationTimedOut
    case audioBufferOverflow
}

extension RealtimeDictationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let error):
            "Realtime transcription could not connect: \(error.localizedDescription)"
        case .streamFailed(let error):
            "Realtime transcription failed: \(error.localizedDescription)"
        case .commitFailed(let error):
            "Realtime transcription could not request the final transcript: \(error.localizedDescription)"
        case .streamEnded:
            "Realtime transcription ended before the final transcript"
        case .finalizationTimedOut:
            "Realtime transcription did not deliver the final transcript in time"
        case .audioBufferOverflow:
            "Realtime transcription fell too far behind the recording"
        }
    }
}

enum RealtimeDictationSignal: Sendable {
    case event(RealtimeTranscriptionEvent)
    case eventsEnded
    case connectFailed(any Error)
    case sessionFailed(any Error)
    case commitFailed(any Error)
    case inputRejected(any Error)
    case finishRequested(audioByteCount: Int, unprocessedByteCount: Int)
    case audioDelivered
    case timedOut
}

final class RealtimeDictationInput: Sendable {
    static let maximumPendingSeconds = 60

    private enum Phase { case recording, finished, stopped }

    private struct State {
        var phase = Phase.recording
        var pendingByteCount = 0
        var appendedByteCount = 0
        var dequeuedByteCount = 0
        var firstDequeueAt: ContinuousClock.Instant?
    }

    let audio: AsyncStream<Data>
    private let audioContinuation: AsyncStream<Data>.Continuation
    private let signal: AsyncStream<RealtimeDictationSignal>.Continuation
    private let bytesPerSecond: Int
    private let maximumPendingByteCount: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(bytesPerSecond: Int, maximumPendingByteCount: Int, signal: AsyncStream<RealtimeDictationSignal>.Continuation) {
        (audio, audioContinuation) = AsyncStream<Data>.makeStream()
        self.bytesPerSecond = bytesPerSecond
        self.maximumPendingByteCount = maximumPendingByteCount
        self.signal = signal
    }

    var pendingByteCount: Int {
        state.withLock { $0.pendingByteCount }
    }

    var hasFinished: Bool {
        state.withLock { $0.phase == .finished }
    }

    func append(_ pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        let rejection = state.withLock { state -> (any Error)? in
            guard state.phase == .recording else { return nil }
            guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                state.phase = .stopped
                return SpeechKitError.invalidRequest("PCM16 chunks must contain complete samples")
            }
            guard pcm16.count <= maximumPendingByteCount - state.pendingByteCount else {
                state.phase = .stopped
                return RealtimeDictationError.audioBufferOverflow
            }
            state.pendingByteCount += pcm16.count
            state.appendedByteCount += pcm16.count
            audioContinuation.yield(pcm16)
            return nil
        }
        if let rejection {
            audioContinuation.finish()
            signal.yield(.inputRejected(rejection))
        }
    }

    func finish() {
        let now = ContinuousClock.now
        let request = state.withLock { state -> RealtimeDictationSignal? in
            guard state.phase == .recording else { return nil }
            state.phase = .finished
            let realTimeByteCount = state.firstDequeueAt.map { Self.byteCount(of: now - $0, bytesPerSecond: bytesPerSecond) } ?? 0
            return .finishRequested(
                audioByteCount: state.appendedByteCount,
                unprocessedByteCount: state.pendingByteCount + max(0, state.dequeuedByteCount - realTimeByteCount)
            )
        }
        guard let request else { return }
        signal.yield(request)
        audioContinuation.finish()
    }

    func didDequeue(_ byteCount: Int) {
        let now = ContinuousClock.now
        state.withLock { state in
            state.pendingByteCount -= byteCount
            state.dequeuedByteCount += byteCount
            if state.firstDequeueAt == nil { state.firstDequeueAt = now }
        }
    }

    private static func byteCount(of duration: Duration, bytesPerSecond: Int) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * bytesPerSecond + Int(Double(attoseconds) / 1e18 * Double(bytesPerSecond))
    }

    func stop() {
        state.withLock { state in
            if state.phase == .recording { state.phase = .stopped }
        }
        audioContinuation.finish()
    }
}

final class RealtimeDictationRun: Sendable {
    private enum Connection { case connecting, connected, failed, tornDown }

    private let session: any RealtimeTranscriptionSession
    private let input: RealtimeDictationInput
    private let signal: AsyncStream<RealtimeDictationSignal>.Continuation
    private let connection = OSAllocatedUnfairLock(initialState: Connection.connecting)

    init(
        session: any RealtimeTranscriptionSession,
        input: RealtimeDictationInput,
        signal: AsyncStream<RealtimeDictationSignal>.Continuation
    ) {
        self.session = session
        self.input = input
        self.signal = signal
    }

    func transcribe(_ signals: AsyncStream<RealtimeDictationSignal>) async throws -> String {
        let streaming = Task { await connectAndStream() }
        let outcome = await withTaskGroup(of: Void.self, returning: Result<String, any Error>.self) { group in
            let outcome: Result<String, any Error>
            do {
                outcome = .success(try await follow(signals, group: &group))
            } catch {
                outcome = .failure(Task.isCancelled ? CancellationError() : error)
            }
            group.cancelAll()
            streaming.cancel()
            await tearDown()
            return outcome
        }
        return try outcome.get()
    }

    private func follow(
        _ signals: AsyncStream<RealtimeDictationSignal>,
        group: inout TaskGroup<Void>
    ) async throws -> String {
        var transcript = RealtimeTranscript()
        var finalizationCount = 0
        var finalizationCountAtCommit: Int?
        for await received in signals {
            switch received {
            case .event(.committedTranscript(let text)):
                transcript.append(text)
            case .event(.finalizationCompleted):
                finalizationCount += 1
                if let finalizationCountAtCommit, finalizationCount > finalizationCountAtCommit {
                    return transcript.text ?? ""
                }
            case .eventsEnded:
                throw RealtimeDictationError.streamEnded
            case .connectFailed(let error):
                throw RealtimeDictationError.connectionFailed(error)
            case .sessionFailed(let error):
                throw RealtimeDictationError.streamFailed(error)
            case .commitFailed(let error):
                throw RealtimeDictationError.commitFailed(error)
            case .inputRejected(let error):
                throw error
            case .finishRequested(let audioByteCount, let unprocessedByteCount):
                guard audioByteCount > 0 else { return "" }
                let unprocessedAudio = Duration.seconds(unprocessedByteCount / MemoryLayout<Int16>.size) / session.sampleRate
                let timeout = session.finalizationTimeout + unprocessedAudio
                group.addTask { [signal] in
                    guard (try? await Task.sleep(for: timeout)) != nil else { return }
                    signal.yield(.timedOut)
                }
            case .audioDelivered:
                finalizationCountAtCommit = finalizationCount
                group.addTask { [session, signal] in
                    do {
                        try await session.requestCommit()
                    } catch {
                        signal.yield(.commitFailed(error))
                    }
                }
            case .timedOut:
                throw RealtimeDictationError.finalizationTimedOut
            }
        }
        throw CancellationError()
    }

    private func connectAndStream() async {
        let events: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>
        do {
            try Task.checkCancellation()
            events = try await session.connectTranscription()
        } catch {
            connection.withLock { connection in
                if connection == .connecting { connection = .failed }
            }
            signal.yield(.connectFailed(error))
            return
        }
        let isTornDown = connection.withLock { connection in
            guard connection == .connecting else { return true }
            connection = .connected
            return false
        }
        guard !isTornDown else {
            await session.disconnect()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.forward(events) }
            group.addTask { await self.sendAudio() }
        }
    }

    private func forward(_ events: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>) async {
        do {
            for try await event in events {
                signal.yield(.event(event))
            }
            signal.yield(.eventsEnded)
        } catch {
            signal.yield(.sessionFailed(error))
        }
    }

    private func sendAudio() async {
        for await chunk in input.audio {
            input.didDequeue(chunk.count)
            do {
                try await session.sendAudioChunk(chunk)
            } catch {
                signal.yield(.sessionFailed(error))
                return
            }
        }
        guard !Task.isCancelled, input.hasFinished else { return }
        signal.yield(.audioDelivered)
    }

    private func tearDown() async {
        input.stop()
        signal.finish()
        let mayHoldConnection = connection.withLock { connection in
            defer { connection = .tornDown }
            return connection != .failed
        }
        if mayHoldConnection {
            await session.disconnect()
        }
    }
}
