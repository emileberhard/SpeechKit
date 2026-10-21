import Foundation
import os

/// One non-replayable HTTP upload. Provider wire formats stay with adapters.
final class StreamingHTTPUpload: NSObject, URLSessionDataDelegate, Sendable {
    struct Response: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct State {
        var input: InputStream?
        var body: StreamingHTTPBody?
        var task: URLSessionUploadTask?
        var session: URLSession?
        var data = Data()
        var bodyClosed = false
        var hasStarted = false
        var result: Result<Response, any Error>?
        var waiter: CheckedContinuation<Response, any Error>?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let suffix: Data
    private let failure: @Sendable (HTTPURLResponse) -> any Error
    private let maximumResponseBytes: Int
    private let transport: SpeechRelayTransport?

    init(
        request: URLRequest,
        prefix: Data,
        suffix: Data,
        configuration: URLSessionConfiguration,
        transport: SpeechRelayTransport?,
        failure: @escaping @Sendable (HTTPURLResponse) -> any Error,
        bufferCapacity: Int,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024
    ) throws {
        guard request.httpBody == nil, request.httpBodyStream == nil,
              request.value(forHTTPHeaderField: "Content-Length") == nil else {
            throw SpeechKitError.invalidRequest("A progressive upload supplies its own unknown-length body")
        }
        guard bufferCapacity > 0, maximumResponseBytes > 0 else {
            throw SpeechKitError.invalidConfiguration("Upload buffer limits must be positive")
        }
        self.suffix = suffix
        self.failure = failure
        self.maximumResponseBytes = maximumResponseBytes
        self.transport = transport
        super.init()

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 16_384, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw ProgressiveTranscriptionError.bodyStreamFailed }
        let body = StreamingHTTPBody(
            output: output,
            capacity: bufferCapacity,
            onFailure: { [weak self] error in self?.complete(.failure(error)) },
            onClose: { [weak self] in self?.state.withLockUnchecked { $0.bodyClosed = true } }
        )
        try body.append(prefix)
        let session = URLSession(configuration: transport?.prepared(configuration) ?? configuration, delegate: self, delegateQueue: nil)
        let task = session.uploadTask(withStreamedRequest: request)
        state.withLockUnchecked {
            $0.input = input
            $0.body = body
            $0.session = session
            $0.task = task
        }
    }

    func start() {
        let task = state.withLockUnchecked { state -> URLSessionUploadTask? in
            guard state.result == nil, !state.hasStarted else { return nil }
            state.hasStarted = true
            return state.task
        }
        task?.resume()
    }

    func append(_ data: Data) throws {
        let body = try activeBody()
        do {
            try body.append(data)
        } catch {
            complete(.failure(error))
            throw error
        }
    }

    func finish() throws {
        let body = try activeBody()
        do {
            try body.finish(suffix: suffix)
        } catch {
            complete(.failure(error))
            throw error
        }
    }

    private func activeBody() throws -> StreamingHTTPBody {
        try state.withLockUnchecked {
            if let result = $0.result {
                _ = try result.get()
                throw ProgressiveTranscriptionError.alreadyFinished
            }
            return $0.body!
        }
    }

    func response() async throws -> Response {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let result = state.withLockUnchecked { state -> Result<Response, any Error>? in
                    if let result = state.result { return result }
                    guard state.waiter == nil else {
                        return .failure(ProgressiveTranscriptionError.alreadyFinished)
                    }
                    state.waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { complete(.failure(CancellationError())) }

    private func complete(_ result: Result<Response, any Error>) {
        let cleanup = state.withLockUnchecked { state -> (
            CheckedContinuation<Response, any Error>?, StreamingHTTPBody?, URLSession?
        )? in
            guard state.result == nil else { return nil }
            state.result = result
            let cleanup = (state.waiter, state.body, state.session)
            state.waiter = nil
            state.body = nil
            state.session = nil
            state.task = nil
            state.input = nil
            state.data = Data()
            return cleanup
        }
        guard let cleanup else { return }
        cleanup.1?.cancel()
        // Also starts an as-yet unused writer so its output closes on its owner.
        cleanup.1?.start()
        cleanup.2?.invalidateAndCancel()
        cleanup.0?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        transport?.answer(challenge) ?? (.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        transport?.answer(challenge) ?? (.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        let pair = state.withLockUnchecked { state -> (InputStream?, StreamingHTTPBody?) in
            guard state.result == nil else { return (nil, nil) }
            let input = state.input
            state.input = nil
            return (input, state.body)
        }
        guard let input = pair.0 else {
            completionHandler(nil)
            complete(.failure(ProgressiveTranscriptionError.bodyCannotBeReplayed))
            return
        }
        pair.1?.start()
        completionHandler(input)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLockUnchecked { state in
            guard state.result == nil else { return false }
            guard data.count <= maximumResponseBytes - state.data.count else { return true }
            state.data.append(data)
            return false
        }
        if tooLarge { complete(.failure(ProgressiveTranscriptionError.responseTooLarge)) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        complete(.failure(ProgressiveTranscriptionError.bodyCannotBeReplayed))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            complete(.failure(error))
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            complete(.failure(SpeechKitError.invalidResponse))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            complete(.failure(failure(response)))
            return
        }
        let snapshot = state.withLockUnchecked { ($0.data, $0.bodyClosed) }
        if !snapshot.1 {
            complete(.failure(ProgressiveTranscriptionError.incompleteUpload))
        } else {
            complete(.success(Response(data: snapshot.0, response: response)))
        }
    }
}
