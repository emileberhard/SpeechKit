import Foundation
import Testing
@testable import SpeechKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_BENCHMARK"] == "1"), .serialized)
struct AppendBenchmarkTests {
    private struct Owner: Codable, Sendable { let name: String }

    private static func report(_ name: String, _ body: () throws -> Void) rethrows {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<15 {
            let start = clock.now
            try body()
            samples.append(start.duration(to: clock.now))
        }
        samples.sort()
        print("BENCH \(name) median=\(samples[samples.count / 2]) min=\(samples[0])")
    }

    @Test func recordingWriterAppend() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecordingStore<Owner>(directory: directory, retention: try DictationRecordingRetention(maximumCount: 100, maximumAge: .seconds(3_600)))
        let chunk = Data(repeating: 1, count: 640)
        var writers: [DictationRecordingWriter<Owner>] = []
        for _ in 0..<15 { writers.append(try await store.startRecording(owner: Owner(name: "bench"), sampleRate: 16_000)) }
        var index = 0
        Self.report("recordingWriterAppend x5000") {
            let writer = writers[index]
            index += 1
            for _ in 0..<5_000 { writer.append(chunk) }
        }
        for writer in writers { _ = try await writer.finish() }
    }

    @Test func realtimeInputAppend() {
        let chunk = Data(repeating: 1, count: 640)
        Self.report("realtimeInputAppend x20000") {
            let (_, signal) = AsyncStream<RealtimeDictationSignal>.makeStream()
            let input = RealtimeDictationInput(bytesPerSecond: 32_000, maximumPendingByteCount: 64 * 1_024 * 1_024, signal: signal)
            for _ in 0..<20_000 {
                input.append(chunk)
                input.didDequeue(chunk.count)
            }
            input.stop()
        }
    }

    @Test func streamedBodyAppend() throws {
        let chunk = Data(repeating: 1, count: 640)
        try Self.report("streamedBodyAppend x20000") {
            var input: InputStream?
            var output: OutputStream?
            Stream.getBoundStreams(withBufferSize: 16_384, inputStream: &input, outputStream: &output)
            let body = StreamingHTTPBody(output: output!, capacity: 64 * 1_024 * 1_024, onFailure: { _ in }, onClose: {})
            for _ in 0..<20_000 { try body.append(chunk) }
            body.cancel()
        }
    }
}
