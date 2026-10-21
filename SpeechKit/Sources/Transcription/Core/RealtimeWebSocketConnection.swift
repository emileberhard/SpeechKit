import Foundation
import OSLog

actor RealtimeWebSocketConnection<Event: Sendable> {
    typealias EventDecoder = @Sendable (Data) throws -> Event?
    typealias ReadyEventPredicate = @Sendable (Event) -> Bool
    typealias TerminalEventPredicate = @Sendable (Event) -> Bool
    typealias InvalidMessageErrorBuilder = @Sendable (String) -> any Error & Sendable

    private let providerName: String
    private let logger: Logger
    private let session: URLSession
    private let relay: SpeechRelay?
    private let decodeEvent: EventDecoder
    private let isReadyEvent: ReadyEventPredicate
    private let isTerminalEvent: TerminalEventPredicate?
    private let alreadyConnectedError: any Error & Sendable
    private let notConnectedError: any Error & Sendable
    private let invalidMessageError: InvalidMessageErrorBuilder
    private let pingIntervalNanoseconds: UInt64?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var pendingReadyContinuations: [CheckedContinuation<Void, Error>] = []
    private(set) var isReady = false
    private var hasTerminated = false
    private var isDisconnecting = false

    init(
        providerName: String,
        logger: Logger,
        session: URLSession,
        relay: SpeechRelay?,
        decodeEvent: @escaping EventDecoder,
        isReadyEvent: @escaping ReadyEventPredicate,
        isTerminalEvent: TerminalEventPredicate? = nil,
        alreadyConnectedError: any Error & Sendable,
        notConnectedError: any Error & Sendable,
        invalidMessageError: @escaping InvalidMessageErrorBuilder,
        pingIntervalNanoseconds: UInt64? = 20_000_000_000
    ) {
        self.providerName = providerName
        self.logger = logger
        self.session = session
        self.relay = relay
        self.decodeEvent = decodeEvent
        self.isReadyEvent = isReadyEvent
        self.isTerminalEvent = isTerminalEvent
        self.alreadyConnectedError = alreadyConnectedError
        self.notConnectedError = notConnectedError
        self.invalidMessageError = invalidMessageError
        self.pingIntervalNanoseconds = pingIntervalNanoseconds
    }

    func connect(request: URLRequest) throws -> AsyncThrowingStream<Event, Error> {
        guard webSocketTask == nil else {
            throw alreadyConnectedError
        }

        let task = session.webSocketTask(with: request)
        task.resume()
        logger.info("Connecting \(self.providerName, privacy: .public) session to \(Self.logDescription(for: request.url), privacy: .public)")

        webSocketTask = task
        isReady = false
        hasTerminated = false
        isDisconnecting = false

        let stream = AsyncThrowingStream<Event, Error> { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task {
                    await self?.disconnect(code: .normalClosure)
                }
            }
        }

        startReceiveLoop()
        startPingLoop(for: task)
        return stream
    }

    func waitUntilReady() async throws {
        if isReady {
            return
        }

        guard webSocketTask != nil else {
            throw notConnectedError
        }

        try await withCheckedThrowingContinuation { continuation in
            logger.debug("Waiting for \(self.providerName, privacy: .public) session readiness")
            pendingReadyContinuations.append(continuation)
        }
    }

    func send(_ message: String) async throws {
        guard let webSocketTask else {
            throw notConnectedError
        }

        do {
            try await webSocketTask.send(.string(message))
        } catch {
            throw transportError(error, task: webSocketTask)
        }
    }

    func send(_ data: Data) async throws {
        guard let webSocketTask else {
            throw notConnectedError
        }

        do {
            try await webSocketTask.send(.data(data))
        } catch {
            throw transportError(error, task: webSocketTask)
        }
    }

    func waitUntilTerminal(timeout: Duration, pollInterval: Duration = .milliseconds(10)) async throws -> Bool {
        let clock = ContinuousClock()
        let startedAt = clock.now

        while startedAt.duration(to: clock.now) < timeout {
            if hasTerminated {
                return true
            }
            guard webSocketTask != nil else {
                throw notConnectedError
            }
            try await Task.sleep(for: pollInterval)
        }

        return hasTerminated
    }

    func disconnect(code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        guard webSocketTask != nil || receiveTask != nil || continuation != nil else {
            return
        }

        isDisconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil

        let currentContinuation = continuation
        continuation = nil
        currentContinuation?.finish()

        webSocketTask?.cancel(with: code, reason: nil)
        webSocketTask = nil
        isReady = false
        hasTerminated = false
        finishPendingReadyContinuations(with: notConnectedError)
        logger.info("Disconnected \(self.providerName, privacy: .public) session with code \(code.rawValue, privacy: .public)")
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func startPingLoop(for task: URLSessionWebSocketTask) {
        pingTask?.cancel()

        guard let pingIntervalNanoseconds else { return }

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pingIntervalNanoseconds)
                    try Task.checkCancellation()
                    try await Self.sendPing(on: task)
                } catch is CancellationError {
                    return
                } catch {
                    await self?.handlePingFailure(error, task: task)
                    return
                }
            }
        }
    }

    private func runReceiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let webSocketTask else {
                    throw notConnectedError
                }

                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await webSocketTask.receive()
                } catch {
                    throw transportError(error, task: webSocketTask)
                }
                let data = try messageData(from: message)
                guard let event = try decodeEvent(data) else {
                    continue
                }

                if isReadyEvent(event) {
                    isReady = true
                    finishPendingReadyContinuations()
                }

                if isTerminalEvent?(event) == true {
                    hasTerminated = true
                }

                continuation?.yield(event)
            }

            resetAfterReceiveLoop()
        } catch is CancellationError {
            resetAfterReceiveLoop()
            finishPendingReadyContinuations(with: notConnectedError)
        } catch {
            if isDisconnecting || hasTerminated {
                logger.debug("\(self.providerName, privacy: .public) receive loop ended during disconnect: \(String(describing: error), privacy: .public)")
                resetAfterReceiveLoop()
                finishPendingReadyContinuations(with: notConnectedError)
                return
            }

            logger.error("\(self.providerName, privacy: .public) receive loop failed: \(String(describing: error), privacy: .public)")
            failConnection(with: error)
        }
    }

    private func resetAfterReceiveLoop() {
        pingTask?.cancel()
        pingTask = nil
        continuation?.finish()
        continuation = nil
        webSocketTask = nil
        isReady = false
        isDisconnecting = false
    }

    private func handlePingFailure(_ error: Error, task: URLSessionWebSocketTask) {
        guard webSocketTask === task, !isDisconnecting else { return }

        logger.error("\(self.providerName, privacy: .public) websocket ping failed: \(String(describing: error), privacy: .public)")
        failConnection(with: transportError(error, task: task))
    }

    private func failConnection(with error: Error) {
        pingTask?.cancel()
        pingTask = nil

        let task = webSocketTask
        webSocketTask = nil
        isReady = false
        isDisconnecting = false

        continuation?.finish(throwing: error)
        continuation = nil
        task?.cancel(with: .goingAway, reason: nil)
        finishPendingReadyContinuations(with: error)
    }

    private nonisolated static func sendPing(on task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let oneShotContinuation = OneShotContinuation(continuation)
            task.sendPing { error in
                if let error {
                    oneShotContinuation.resume(throwing: error)
                } else {
                    oneShotContinuation.resume()
                }
            }
        }
    }

    private func messageData(from message: URLSessionWebSocketTask.Message) throws -> Data {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            throw invalidMessageError("Unsupported websocket message type")
        }
    }

    private func finishPendingReadyContinuations(with error: Error? = nil) {
        let continuations = pendingReadyContinuations
        pendingReadyContinuations.removeAll(keepingCapacity: false)

        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private nonisolated func transportError(_ error: Error, task: URLSessionWebSocketTask) -> Error {
        if error is CancellationError {
            return error
        }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return relay?.rejection(in: response)
                ?? SpeechKitError.webSocketHandshakeFailed(statusCode: response.statusCode)
        }
        if task.closeCode != .invalid {
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            return relay?.rejection(closeReason: reason)
                ?? SpeechKitError.webSocketClosed(code: task.closeCode.rawValue, reason: reason)
        }
        return error
    }

    private nonisolated static func logDescription(for url: URL?) -> String {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "unknown"
        }

        components.query = nil
        components.fragment = nil
        return components.string ?? "unknown"
    }
}

private final class OneShotContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        takeContinuation()?.resume()
    }

    func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }

        let current = continuation
        continuation = nil
        return current
    }
}
