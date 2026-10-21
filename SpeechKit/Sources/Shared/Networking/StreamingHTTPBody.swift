import Foundation
import os

/// A bounded producer queue feeding a native bound stream. Foundation stream
/// operations and callbacks stay on one dedicated run loop, never an audio
/// callback or Swift's cooperative executor.
final class StreamingHTTPBody: NSObject, StreamDelegate, @unchecked Sendable {
    private enum DrainAction { case cancelled, finished, write }
    private struct State {
        var chunks: [Data] = []
        var bufferedBytes = 0
        var isFinishing = false
        var isCancelled = false
        var hasStarted = false
        var runLoop: CFRunLoop?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let capacity: Int
    private let output: OutputStream
    private let onFailure: @Sendable (any Error) -> Void
    private let onClose: @Sendable () -> Void

    // Accessed only by the stream's worker thread.
    private var pending = Data()
    private var pendingOffset = 0
    private var isClosed = false

    init(
        output: OutputStream,
        capacity: Int,
        onFailure: @escaping @Sendable (any Error) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.output = output
        self.capacity = capacity
        self.onFailure = onFailure
        self.onClose = onClose
    }

    func append(_ data: Data) throws {
        let runLoop = try state.withLockUnchecked { state -> CFRunLoop? in
            guard !state.isCancelled else { throw CancellationError() }
            guard !state.isFinishing else { throw ProgressiveTranscriptionError.alreadyFinished }
            guard data.count <= capacity - state.bufferedBytes else {
                throw ProgressiveTranscriptionError.bufferOverflow
            }
            if !data.isEmpty {
                state.chunks.append(data)
                state.bufferedBytes += data.count
            }
            return state.runLoop
        }
        wake(runLoop)
    }

    func finish(suffix: Data) throws {
        let runLoop = try state.withLockUnchecked { state -> CFRunLoop? in
            guard !state.isCancelled else { throw CancellationError() }
            guard !state.isFinishing else { throw ProgressiveTranscriptionError.alreadyFinished }
            guard suffix.count <= capacity - state.bufferedBytes else {
                throw ProgressiveTranscriptionError.bufferOverflow
            }
            state.chunks.append(suffix)
            state.bufferedBytes += suffix.count
            state.isFinishing = true
            return state.runLoop
        }
        wake(runLoop)
    }

    func cancel() {
        let runLoop = state.withLockUnchecked { state in
            state.isCancelled = true
            state.chunks.removeAll()
            return state.runLoop
        }
        wake(runLoop)
    }

    func start() {
        let shouldStart = state.withLockUnchecked { state in
            guard !state.hasStarted else { return false }
            state.hasStarted = true
            return true
        }
        guard shouldStart else { return }
        let thread = Thread { [self] in run() }
        thread.name = "SpeechKit streamed upload"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func wake(_ runLoop: CFRunLoop?) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in drain() }
        CFRunLoopWakeUp(runLoop)
    }

    private func run() {
        let runLoop = CFRunLoopGetCurrent()!
        output.delegate = self
        output.schedule(in: .current, forMode: .default)
        output.open()
        state.withLockUnchecked { $0.runLoop = runLoop }
        drain()
        if !isClosed { CFRunLoopRun() }
        output.remove(from: .current, forMode: .default)
        output.delegate = nil
        state.withLockUnchecked {
            $0.runLoop = nil
            $0.chunks.removeAll()
            $0.bufferedBytes = 0
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted, .hasSpaceAvailable:
            drain()
        case .errorOccurred, .endEncountered:
            guard !isClosed else { return }
            close()
            onFailure(ProgressiveTranscriptionError.bodyStreamFailed)
        default:
            break
        }
    }

    private func drain() {
        guard !isClosed else { return }
        while true {
            let action = state.withLockUnchecked { state -> DrainAction in
                if state.isCancelled { return .cancelled }
                if pendingOffset == pending.count {
                    pending = state.chunks.isEmpty ? Data() : state.chunks.removeFirst()
                    pendingOffset = 0
                }
                return pending.isEmpty && state.isFinishing ? .finished : .write
            }
            switch action {
            case .cancelled:
                close()
                return
            case .finished:
                onClose()
                close()
                return
            case .write:
                break
            }
            guard pendingOffset < pending.count, output.hasSpaceAvailable else { return }
            let written = pending.withUnsafeBytes { bytes in
                output.write(
                    bytes.bindMemory(to: UInt8.self).baseAddress! + pendingOffset,
                    maxLength: min(4_096, pending.count - pendingOffset)
                )
            }
            guard written > 0 else {
                close()
                onFailure(ProgressiveTranscriptionError.bodyStreamFailed)
                return
            }
            pendingOffset += written
            state.withLockUnchecked { $0.bufferedBytes -= written }
        }
    }

    private func close() {
        isClosed = true
        state.withLockUnchecked { $0.runLoop = nil }
        output.close()
        pending = Data()
        CFRunLoopStop(CFRunLoopGetCurrent())
    }
}
