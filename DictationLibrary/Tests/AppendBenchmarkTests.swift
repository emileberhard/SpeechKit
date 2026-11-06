import AVFAudio
import Foundation
import Testing
@testable import DictationLibrary

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPEECHKIT_BENCHMARK"] == "1"), .serialized)
struct CaptureAppendBenchmarkTests {
    @Test(arguments: [(44_100.0, AVAudioChannelCount(1)), (48_000.0, AVAudioChannelCount(2))])
    func captureAppend(sampleRate: Double, channels: AVAudioChannelCount) async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try TestSupport.store(directory, cloud: FakeCloud(), capacity: 4 * 1_024 * 1_024 * 1_024)
        let plan = DictationPlan(unverifiedProfile: TestSupport.profile, context: .chat, capabilities: try TestSupport.capabilities())
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let frames = AVAudioFrameCount(sampleRate / 50)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.4 * sin(Float(i + channel) * 0.05) }
        }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<15 {
            let writer = try await store.beginCapture(plan: plan)
            try writer.configure(format: format)
            let start = clock.now
            for _ in 0..<1_000 { writer.append(buffer) }
            samples.append(start.duration(to: clock.now))
            _ = try await writer.finish()
        }
        samples.sort()
        print("BENCH captureAppend rate=\(Int(sampleRate)) channels=\(channels) median=\(samples[samples.count / 2]) min=\(samples[0])")
    }
}
