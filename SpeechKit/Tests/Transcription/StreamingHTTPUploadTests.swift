import Foundation
import Network
import Synchronization
import Testing
@testable import SpeechKit

@Suite(.timeLimit(.minutes(1)))
struct StreamingHTTPUploadTests {
    @Test func earlyHTTPRejectionFailsWithTheAdapterError() async throws {
        let upload = try makeUpload(path: "unauthorized")
        do {
            _ = try await upload.response()
            Issue.record("Expected HTTP failure")
        } catch SpeechKitError.providerFailure(let message) {
            #expect(message == "status 401")
        }
        #expect(throws: SpeechKitError.self) { try upload.append(Data([0, 0])) }
    }

    @Test func rejectsSuccessBeforeTheBodyHasClosed() async throws {
        let upload = try makeUpload(path: "success")
        await #expect(throws: ProgressiveTranscriptionError.incompleteUpload) { try await upload.response() }
    }

    @Test func cancellationBeforeWaitingIsRemembered() async throws {
        let upload = try makeUpload(path: "pending")
        upload.cancel()
        upload.cancel()
        await #expect(throws: CancellationError.self) { try await upload.response() }
        #expect(throws: CancellationError.self) { try upload.finish() }
    }

    @Test func cancellingTheWaitingTaskCancelsTheUpload() async throws {
        let upload = try makeUpload(path: "pending")
        let waiter = Task { try await upload.response() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(throws: CancellationError.self) { try upload.append(Data([0, 0])) }
    }

    @Test func limitsResponseSizeBeforeDecoding() async throws {
        let upload = try makeUpload(path: "large", responseLimit: 4)
        await #expect(throws: ProgressiveTranscriptionError.responseTooLarge) { try await upload.response() }
    }

    @Test func refusesToReplayTheConsumedBody() throws {
        let upload = try makeUpload(path: "pending", start: false)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.test")!)
        nonisolated(unsafe) var supplied: InputStream?
        upload.urlSession(session, task: task, needNewBodyStream: { input in
            #expect(input != nil)
            supplied = input
        })
        upload.urlSession(session, task: task, needNewBodyStream: { #expect($0 == nil) })
        #expect(throws: ProgressiveTranscriptionError.bodyCannotBeReplayed) { try upload.finish() }
        supplied?.close()
        session.invalidateAndCancel()
    }

    @Test func frameValidationCancelsTheSession() async throws {
        let session = try ProgressiveTranscriptionSession.unansweredTestSession()
        await #expect(throws: SpeechKitError.self) { try await session.appendAudio(Data([0])) }
        await #expect(throws: CancellationError.self) { try await session.finish() }
    }

    @Test func emptyRecordingCannotFinishSuccessfully() async throws {
        let session = try ProgressiveTranscriptionSession.unansweredTestSession()
        await #expect(throws: SpeechKitError.self) { try await session.finish() }
        await #expect(throws: ProgressiveTranscriptionError.alreadyFinished) { try await session.finish() }
    }

    @Test func stalledConnectionBuffersAudioForTheRequestTimeout() async throws {
        let session = try ProgressiveTranscriptionSession.unansweredTestSession(
            requestTimeout: 10,
            maximumAudioBytes: 1_000_000
        )
        let tenthOfASecond = Data(count: 3_200)

        for _ in 0..<100 {
            try await session.appendAudio(tenthOfASecond)
        }
        await #expect(throws: ProgressiveTranscriptionError.bufferOverflow) {
            for _ in 0..<10 {
                try await session.appendAudio(tenthOfASecond)
            }
        }
    }

    @Test(arguments: [true, false])
    func silentTCPPeerFailsBeforeTLSOrAfterTheWholeBody(tls: Bool) async throws {
        let server = try SilentUploadServer()
        defer { server.stop() }
        let port = try await server.start()
        var request = URLRequest(url: URL(string: "\(tls ? "https" : "http")://127.0.0.1:\(port)/upload")!)
        request.httpMethod = "POST"
        let upload = try StreamingHTTPUpload(
            request: request, prefix: Data("prefix".utf8), suffix: Data("suffix".utf8),
            configuration: .ephemeral, transport: nil, failure: Self.failure,
            bufferCapacity: 1_024, stallTimeout: .milliseconds(200)
        )
        defer { upload.cancel() }
        let started = ContinuousClock.now
        upload.start()
        try upload.append(Data([0, 0]))
        try upload.finish()
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            upload.cancel()
        }
        defer { deadline.cancel() }

        await #expect(throws: ProgressiveTranscriptionError.stalled) { try await upload.response() }
        #expect(started.duration(to: .now) < .seconds(2))
        #expect(server.accepted)
        #expect(upload.uploadedBodyByteCount == (tls ? 0 : 14))
        #expect((server.received.range(of: Data("suffix".utf8)) != nil) == !tls)
    }

    @Test(arguments: [true, false])
    func savedUploadSeparatesConnectionStallFromResponseDeadline(tls: Bool) async throws {
        let server = try SilentUploadServer()
        defer { server.stop() }
        let port = try await server.start()
        var request = URLRequest(url: URL(string: "\(tls ? "https" : "http")://127.0.0.1:\(port)/upload")!)
        request.httpMethod = "POST"
        request.httpBody = Data("saved audio".utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let observer = AzureSpeechUploadObserver(bodyBytes: 11, transport: nil, completed: nil,
                                                 stallTimeout: .milliseconds(200), responseTimeout: .milliseconds(500))
        defer { observer.stop() }
        let started = ContinuousClock.now
        let operation = Task { try await session.data(for: request, delegate: observer) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(3))
            operation.cancel()
        }
        defer { deadline.cancel() }
        do {
            _ = try await operation.value
            Issue.record("Expected the saved upload to time out")
        } catch {
            if tls { #expect(observer.failure as? ProgressiveTranscriptionError == .stalled) }
            else { #expect((observer.failure as? URLError)?.code == .timedOut) }
        }
        #expect(server.accepted)
        #expect(started.duration(to: .now) < .seconds(2))
        if !tls {
            #expect(server.received.range(of: Data("saved audio".utf8)) != nil)
            #expect(started.duration(to: .now) >= .milliseconds(500))
        }
    }

    private func makeUpload(path: String, responseLimit: Int = 1_024, start: Bool = true) throws -> StreamingHTTPUpload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadTestProtocol.self]
        var request = URLRequest(url: URL(string: "https://example.test/\(path)")!)
        request.httpMethod = "POST"
        let upload = try StreamingHTTPUpload(
            request: request, prefix: Data("prefix".utf8), suffix: Data("suffix".utf8),
            configuration: configuration, transport: nil, failure: Self.failure,
            bufferCapacity: 1_024, maximumResponseBytes: responseLimit
        )
        if start { upload.start() }
        return upload
    }

    private static let failure: @Sendable (HTTPURLResponse) -> any Error = {
        SpeechKitError.providerFailure("status \($0.statusCode)")
    }
}

extension ProgressiveTranscriptionSession {
    static func unansweredTestSession(
        requestTimeout: TimeInterval = 60,
        maximumAudioBytes: Int = 100
    ) throws -> ProgressiveTranscriptionSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadTestProtocol.self]
        configuration.timeoutIntervalForRequest = requestTimeout
        var request = URLRequest(url: URL(string: "https://example.test/pending")!)
        request.httpMethod = "POST"
        return try .init(
            sampleRate: 16_000, maximumAudioBytes: maximumAudioBytes, request: request,
            bodyPrefix: Data(), bodySuffix: Data(), sessionConfiguration: configuration, transport: nil,
            failure: { SpeechKitError.providerFailure("status \($0.statusCode)") },
            decode: { _, _ in .init(text: "", providerID: "test") }
        )
    }
}

private final class UploadTestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path != "/pending" else { return }
        let status = request.url?.path == "/unauthorized" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("sensitive response body".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SilentUploadServer: Sendable {
    private struct State {
        var connections: [NWConnection] = []
        var received = Data()
    }

    private let state = Mutex(State())
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SpeechKitTests.SilentUpload")
    var accepted: Bool { state.withLock { !$0.connections.isEmpty } }
    var received: Data { state.withLock { $0.received } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.state.withLock { $0.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.state.withLock { $0.received.append(data) } }
            if !complete && error == nil { self.receive(connection) }
        }
    }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }
}
