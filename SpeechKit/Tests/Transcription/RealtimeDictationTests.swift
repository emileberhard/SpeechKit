import Foundation
import Testing
@testable import SpeechKit

@Suite(.timeLimit(.minutes(1)))
struct RealtimeDictationTests {
    private let chunks = (0..<3).map { Data(repeating: UInt8($0 + 1), count: 320) }

    @Test func audioAppendedBeforeTheConnectionArrivesInOrder() async throws {
        let session = ScriptedRealtimeSession(connect: .afterRelease, commit: .finalizes("hello there"))
        let dictation = RealtimeDictation(session: session)

        chunks.forEach(dictation.append)
        await session.releaseConnect()

        #expect(try await dictation.finish() == "hello there")
        #expect(await session.sentChunks == chunks)
        #expect(await session.commitCount == 1)
        #expect(await session.disconnectCount == 1)
    }

    @Test func finalizationsBeforeTheFinalCommitDoNotEndTheDictation() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes("two"))
        let dictation = RealtimeDictation(session: session)
        chunks.forEach(dictation.append)

        await session.feed.send(.success(.committedTranscript("one")))
        await session.feed.send(.success(.finalizationCompleted))
        await session.feed.waitUntilRequested(3)

        #expect(try await dictation.finish() == "one two")
    }

    @Test func missingFinalizationTimesOut() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .isIgnored, finalizationTimeout: .milliseconds(50))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        #expect(await Self.failure(of: dictation) == .finalizationTimedOut)
        #expect(await session.commitCount == 1)
        #expect(await session.disconnectCount == 1)
    }

    @Test func streamEndingBeforeFinalizationFails() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .endsTheStream)
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        #expect(await Self.failure(of: dictation) == .streamEnded)
    }

    @Test func commitFailureFails() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .fails(ScriptedFailure.commit))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        #expect(await Self.failure(of: dictation) == .commitFailed(ScriptedFailure.commit))
    }

    @Test func providerFailureWhileRecordingFails() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes("late"))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        await session.feed.send(.failure(ScriptedFailure.stream))

        #expect(await Self.failure(of: dictation) == .streamFailed(ScriptedFailure.stream))
    }

    @Test func connectFailureCarriesTheUnderlyingErrorAndDropsLaterAudio() async throws {
        let session = ScriptedRealtimeSession(connect: .fails(ScriptedFailure.connect), commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)
        chunks.forEach(dictation.append)

        #expect(await Self.failure(of: dictation) == .connectionFailed(ScriptedFailure.connect))
        dictation.append(chunks[0])
        #expect(await session.sentChunks.isEmpty)
        #expect(await session.disconnectCount == 0)
    }

    @Test func audioBeyondThePendingLimitFailsTheDictation() async throws {
        let session = ScriptedRealtimeSession(connect: .afterRelease, commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)
        let second = Data(count: session.sampleRate * MemoryLayout<Int16>.size)

        for _ in 0...RealtimeDictationInput.maximumPendingSeconds {
            dictation.append(second)
        }

        #expect(await Self.failure(of: dictation) == .audioBufferOverflow)
        #expect(await session.disconnectCount == 1)
        #expect(await session.sentChunks.isEmpty)
    }

    @Test func pendingAudioStaysWithinItsLimit() async {
        let (signals, signal) = AsyncStream<RealtimeDictationSignal>.makeStream()
        let input = RealtimeDictationInput(bytesPerSecond: 32_000, maximumPendingByteCount: 4, signal: signal)

        input.append(Data(count: 2))
        input.append(Data(count: 2))
        input.append(Data(count: 2))
        input.append(Data(count: 2))
        signal.finish()

        #expect(input.pendingByteCount == 4)
        var rejections: [DictationFailure?] = []
        for await received in signals {
            guard case .inputRejected(let error) = received else { continue }
            rejections.append((error as? RealtimeDictationError).map(DictationFailure.init))
        }
        #expect(rejections == [.audioBufferOverflow])
    }

    @Test func finishCountsAudioTheProviderHasNotHadTimeToProcess() async {
        let (signals, signal) = AsyncStream<RealtimeDictationSignal>.makeStream()
        let input = RealtimeDictationInput(bytesPerSecond: 32_000, maximumPendingByteCount: 1_000_000, signal: signal)
        input.append(Data(count: 64_000))
        input.append(Data(count: 32_000))
        input.didDequeue(64_000)

        input.finish()
        signal.finish()

        var requests: [(audio: Int, unprocessed: Int)] = []
        for await received in signals {
            if case .finishRequested(let audio, let unprocessed) = received { requests.append((audio, unprocessed)) }
        }
        #expect(requests.count == 1)
        #expect(requests.first?.audio == 96_000)
        #expect((90_000...96_000).contains(requests.first?.unprocessed ?? 0))
    }

    @Test func partialSampleFailsTheDictation() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)

        dictation.append(Data([0x01]))

        await #expect(throws: SpeechKitError.self) { try await dictation.finish() }
    }

    @Test func cancellingTheFinishThrowsCancellation() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .isIgnored)
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        let finish = Task { try await dictation.finish() }
        await session.waitForCommit()
        finish.cancel()

        await #expect(throws: CancellationError.self) { try await finish.value }
        #expect(await session.disconnectCount == 1)
    }

    @Test func cancelTearsDownTheSession() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])
        await session.waitForChunks(1)

        await dictation.cancel()

        await #expect(throws: CancellationError.self) { try await dictation.finish() }
        #expect(await session.commitCount == 0)
        #expect(await session.disconnectCount == 1)
    }

    @Test func cancelAbortsAConnectionInProgress() async throws {
        let session = ScriptedRealtimeSession(connect: .afterRelease, commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        await dictation.cancel()

        #expect(await session.disconnectCount == 1)
        await session.releaseConnect()
        #expect(await session.sentChunks.isEmpty)
    }

    @Test func finalizedEmptyTranscriptIsEmpty() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes(nil))
        let dictation = RealtimeDictation(session: session)
        dictation.append(chunks[0])

        #expect(try await dictation.finish() == "")
    }

    @Test func dictationWithoutAudioSkipsTheCommit() async throws {
        let session = ScriptedRealtimeSession(connect: .immediately, commit: .finalizes("never"))
        let dictation = RealtimeDictation(session: session)

        #expect(try await dictation.finish() == "")
        #expect(await session.commitCount == 0)
    }

    private static func failure(of dictation: RealtimeDictation) async -> DictationFailure? {
        await #expect(throws: RealtimeDictationError.self) { try await dictation.finish() }.map(DictationFailure.init)
    }
}

private enum DictationFailure: Equatable {
    case connectionFailed(ScriptedFailure?)
    case streamFailed(ScriptedFailure?)
    case commitFailed(ScriptedFailure?)
    case streamEnded
    case finalizationTimedOut
    case audioBufferOverflow

    init(_ error: RealtimeDictationError) {
        switch error {
        case .connectionFailed(let cause): self = .connectionFailed(cause as? ScriptedFailure)
        case .streamFailed(let cause): self = .streamFailed(cause as? ScriptedFailure)
        case .commitFailed(let cause): self = .commitFailed(cause as? ScriptedFailure)
        case .streamEnded: self = .streamEnded
        case .finalizationTimedOut: self = .finalizationTimedOut
        case .audioBufferOverflow: self = .audioBufferOverflow
        }
    }
}

private enum ScriptedFailure: Error, Equatable {
    case connect, stream, commit
}

private actor EventFeed {
    private var queued: [Result<RealtimeTranscriptionEvent?, any Error>] = []
    private var consumer: CheckedContinuation<Result<RealtimeTranscriptionEvent?, any Error>, Never>?
    private var requestCount = 0
    private var requestWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func next() async throws -> RealtimeTranscriptionEvent? {
        requestCount += 1
        if let waiter = requestWaiter, requestCount >= waiter.count {
            requestWaiter = nil
            waiter.continuation.resume()
        }
        if !queued.isEmpty {
            return try queued.removeFirst().get()
        }
        return try await withCheckedContinuation { consumer = $0 }.get()
    }

    func send(_ item: Result<RealtimeTranscriptionEvent?, any Error>) {
        if let consumer {
            self.consumer = nil
            consumer.resume(returning: item)
        } else {
            queued.append(item)
        }
    }

    func waitUntilRequested(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { requestWaiter = (count, $0) }
    }
}

private actor ScriptedRealtimeSession: RealtimeTranscriptionSession {
    enum Connect {
        case immediately
        case afterRelease
        case fails(any Error)
    }

    enum Commit {
        case finalizes(String?)
        case isIgnored
        case endsTheStream
        case fails(any Error)
    }

    nonisolated let sampleRate = 16_000
    nonisolated let feed = EventFeed()
    private nonisolated let timeout: Duration
    private let connect: Connect
    private let commit: Commit
    private(set) var sentChunks: [Data] = []
    private(set) var commitCount = 0
    private(set) var disconnectCount = 0
    private var isConnectReleased = false
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private let commits: AsyncStream<Void>
    private let commitSignal: AsyncStream<Void>.Continuation
    private let chunkSignal: AsyncStream<Void>.Continuation
    private let chunkArrivals: AsyncStream<Void>

    init(connect: Connect, commit: Commit, finalizationTimeout: Duration = .seconds(10)) {
        self.connect = connect
        self.commit = commit
        self.timeout = finalizationTimeout
        (commits, commitSignal) = AsyncStream<Void>.makeStream()
        (chunkArrivals, chunkSignal) = AsyncStream<Void>.makeStream()
    }

    nonisolated var finalizationTimeout: Duration { timeout }

    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        switch connect {
        case .immediately:
            break
        case .afterRelease:
            if !isConnectReleased {
                await withCheckedContinuation { connectWaiter = $0 }
            }
            guard disconnectCount == 0 else { throw CancellationError() }
        case .fails(let error):
            throw error
        }
        let feed = feed
        return AsyncThrowingStream(unfolding: { try await feed.next() })
    }

    func sendAudioChunk(_ audioData: Data) async throws {
        sentChunks.append(audioData)
        chunkSignal.yield()
    }

    func requestCommit() async throws {
        commitCount += 1
        commitSignal.yield()
        switch commit {
        case .finalizes(let text):
            if let text {
                await feed.send(.success(.committedTranscript(text)))
            }
            await feed.send(.success(.finalizationCompleted))
        case .isIgnored:
            break
        case .endsTheStream:
            await feed.send(.success(nil))
        case .fails(let error):
            throw error
        }
    }

    func disconnect() async {
        disconnectCount += 1
        connectWaiter?.resume()
        connectWaiter = nil
        await feed.send(.success(nil))
    }

    func releaseConnect() {
        isConnectReleased = true
        connectWaiter?.resume()
        connectWaiter = nil
    }

    func waitForCommit() async {
        for await _ in commits { return }
    }

    func waitForChunks(_ count: Int) async {
        var arrived = 0
        for await _ in chunkArrivals {
            arrived += 1
            if arrived >= count { return }
        }
    }
}
