import Foundation
import Testing
import os
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
        let supplied = OSAllocatedUnfairLock(uncheckedState: Optional<InputStream>.none)
        upload.urlSession(session, task: task, needNewBodyStream: { input in
            #expect(input != nil)
            supplied.withLockUnchecked { $0 = input }
        })
        upload.urlSession(session, task: task, needNewBodyStream: { #expect($0 == nil) })
        #expect(throws: ProgressiveTranscriptionError.bodyCannotBeReplayed) { try upload.finish() }
        supplied.withLockUnchecked { $0?.close() }
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
