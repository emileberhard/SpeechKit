import Foundation

public enum RealtimeTranscriptionEvent: Sendable, Equatable {
    case committedTranscript(String)
    case finalizationCompleted
}

public protocol RealtimeTranscriptionSession: Sendable {
    var sampleRate: Int { get }
    var finalizationTimeout: Duration { get }
    func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error>
    func sendAudioChunk(_ audioData: Data) async throws
    func requestCommit() async throws
    func disconnect() async
}

extension AsyncThrowingStream where Element: Sendable, Failure == Error {
    func realtimeTranscriptionEvents(
        _ transform: @escaping @Sendable (Element) -> [RealtimeTranscriptionEvent]
    ) -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        realtimeTranscriptionEvents(tracking: ()) { _, event in transform(event) }
    }

    func realtimeTranscriptionEvents<State: Sendable>(
        tracking initialState: State,
        _ transform: @escaping @Sendable (inout State, Element) throws -> [RealtimeTranscriptionEvent]
    ) -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        AsyncThrowingStream<RealtimeTranscriptionEvent, Error> { continuation in
            let relay = Task {
                var state = initialState
                do {
                    for try await event in self {
                        for transcriptionEvent in try transform(&state, event) {
                            continuation.yield(transcriptionEvent)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in relay.cancel() }
        }
    }
}

public actor ProgressiveRealtimeTranscriptionSession: RealtimeTranscriptionSession {
    public nonisolated let sampleRate: Int
    private let provider: any ProgressiveTranscriptionProvider
    private let request: ProgressiveTranscriptionRequest
    private var upload: ProgressiveTranscriptionSession?
    private var continuation: AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.Continuation?
    private var finishTask: Task<Void, Never>?
    private var hasConnected = false
    private var isDisconnected = false

    public init(provider: any ProgressiveTranscriptionProvider, request: ProgressiveTranscriptionRequest) {
        self.provider = provider
        self.request = request
        self.sampleRate = provider.progressiveSampleRate
    }

    public nonisolated var finalizationTimeout: Duration { .seconds(60) }

    public func connectTranscription() async throws -> AsyncThrowingStream<RealtimeTranscriptionEvent, Error> {
        guard !isDisconnected else { throw CancellationError() }
        guard !hasConnected else { throw ProgressiveTranscriptionError.alreadyFinished }
        hasConnected = true
        let session = try await provider.startProgressiveTranscription(request)
        guard !isDisconnected, !Task.isCancelled else {
            await session.cancel()
            throw CancellationError()
        }
        upload = session
        let events = AsyncThrowingStream<RealtimeTranscriptionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        continuation = events.continuation
        return events.stream
    }

    public func sendAudioChunk(_ audioData: Data) async throws {
        guard let upload, !isDisconnected else { throw CancellationError() }
        do {
            try await upload.appendAudio(audioData)
        } catch {
            fail(error)
            throw error
        }
    }

    public func requestCommit() throws {
        guard let upload, !isDisconnected else { throw CancellationError() }
        guard finishTask == nil else { throw ProgressiveTranscriptionError.alreadyFinished }
        finishTask = Task { [weak self] in
            do {
                let result = try await upload.finish()
                await self?.complete(result)
            } catch {
                await self?.fail(error)
            }
        }
    }

    public func disconnect() async {
        isDisconnected = true
        finishTask?.cancel()
        finishTask = nil
        let session = upload
        upload = nil
        continuation?.finish()
        continuation = nil
        await session?.cancel()
    }

    private func complete(_ result: TranscriptionResult) {
        guard !isDisconnected else { return }
        continuation?.yield(.committedTranscript(result.text))
        continuation?.yield(.finalizationCompleted)
    }

    private func fail(_ error: any Error) {
        guard !isDisconnected else { return }
        continuation?.finish(throwing: error)
    }
}
