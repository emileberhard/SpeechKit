import Foundation
import Testing
@testable import SpeechKit

@Suite(.timeLimit(.minutes(1)))
struct StreamingHTTPBodyTests {
    @Test func uploadsBeforeFinishAndPreservesFramingAndOrder() async throws {
        let pair = try BoundStreamTestPair(capacity: 64 * 1_024)
        let first = Data(repeating: 0x11, count: 20_000)
        let second = Data(repeating: 0x22, count: 20_000)
        let prefix = Data("prefix".utf8)
        let suffix = Data("suffix".utf8)
        try pair.body.append(prefix)
        pair.body.start()
        let reader = Task { try await pair.read() }
        try pair.body.append(first)
        for await count in pair.progress {
            if count >= prefix.count + first.count { break }
        }
        // The consumer has received audio while the producer is still open.
        try pair.body.append(second)
        try pair.body.finish(suffix: suffix)
        #expect(try await reader.value == prefix + first + second + suffix)
    }

    @Test func boundsQueuedBytesWithoutDroppingEarlierAudio() async throws {
        let pair = try BoundStreamTestPair(capacity: 8)
        try pair.body.append(Data([1, 2, 3, 4]))
        #expect(throws: ProgressiveTranscriptionError.bufferOverflow) {
            try pair.body.append(Data(repeating: 9, count: 5))
        }
        try pair.body.finish(suffix: Data([5]))
        #expect(throws: ProgressiveTranscriptionError.alreadyFinished) {
            try pair.body.append(Data([6]))
        }
        pair.body.start()
        #expect(try await pair.read() == Data([1, 2, 3, 4, 5]))
    }

    @Test func cancelBeforeStartClosesTheNativeStream() async throws {
        let pair = try BoundStreamTestPair(capacity: 16)
        try pair.body.append(Data([1, 2]))
        pair.body.cancel()
        pair.body.start()
        #expect(throws: CancellationError.self) { try pair.body.append(Data([3])) }
        #expect(try await pair.read().isEmpty)
    }
}

private final class BoundStreamTestPair: @unchecked Sendable {
    let input: InputStream
    let body: StreamingHTTPBody
    let progress: AsyncStream<Int>
    private let progressContinuation: AsyncStream<Int>.Continuation

    init(capacity: Int) throws {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1_024, inputStream: &input, outputStream: &output)
        self.input = try #require(input)
        let progress = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.progress = progress.stream
        self.progressContinuation = progress.continuation
        self.body = StreamingHTTPBody(
            output: try #require(output), capacity: capacity,
            onFailure: { _ in Issue.record("Bound output stream failed") }, onClose: {}
        )
    }

    // InputStream is used by this thread only, including open/close/read.
    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Thread { [self] in
                input.open()
                defer {
                    input.close()
                    progressContinuation.finish()
                }
                var result = Data()
                var bytes = [UInt8](repeating: 0, count: 1_024)
                while true {
                    let count = input.read(&bytes, maxLength: bytes.count)
                    if count < 0 {
                        continuation.resume(throwing: ProgressiveTranscriptionError.bodyStreamFailed)
                        return
                    }
                    if count == 0 {
                        continuation.resume(returning: result)
                        return
                    }
                    result.append(contentsOf: bytes.prefix(count))
                    progressContinuation.yield(result.count)
                }
            }.start()
        }
    }
}
