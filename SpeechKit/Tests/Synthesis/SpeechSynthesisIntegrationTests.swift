import Foundation
import Testing
@testable import SpeechKit

@Suite("Speech synthesis integration")
struct SpeechSynthesisIntegrationTests {
    @Test func geminiStreamsMultiplePCMChunks() async throws {
        guard ProcessInfo.processInfo.environment["RUN_SPEECH_SYNTHESIS_INTEGRATION_TESTS"] == "1" else {
            try Test.cancel("Set RUN_SPEECH_SYNTHESIS_INTEGRATION_TESTS=1 to run paid synthesis tests.")
        }
        let provider = GeminiSpeechSynthesisProvider(
            configuration: try GeminiSpeechSynthesisConfiguration(
                access: IntegrationAccess.provider("gemini")
            )
        )
        let options = try GeminiSpeechSynthesisOptions(
            voice: .achird,
            instructions: "Sound friendly, relaxed, and conversational."
        )

        let transcript = "Hello! This is a streaming speech synthesis check. The response should arrive as several audio chunks so playback can begin before generation finishes. Thanks for helping verify the complete path."
        var pcm = Data()
        var trace: [SpeechStreamDiagnostic.Chunk] = []
        let clock = ContinuousClock()
        let startedAt = clock.now
        var previousChunkAt = startedAt
        for try await chunk in provider.synthesize(
            SpeechSynthesisRequest(
                text: transcript,
                options: options
            )
        ) {
            #expect(chunk.format == .pcm16Mono24kHz)
            #expect(chunk.data.count.isMultiple(of: 2))
            let arrivedAt = clock.now
            pcm.append(chunk.data)
            trace.append(
                .init(
                    index: trace.count + 1,
                    byteCount: chunk.data.count,
                    elapsedSeconds: startedAt.duration(to: arrivedAt).seconds,
                    deliveryGapSeconds: previousChunkAt.duration(to: arrivedAt).seconds,
                    cumulativeAudioSeconds: Double(pcm.count) / 48_000
                )
            )
            previousChunkAt = arrivedAt
        }

        #expect(trace.count > 1)
        #expect(pcm.count > 4_800)

        if let directory = ProcessInfo.processInfo.environment["SPEECHKIT_DIAGNOSTICS_DIRECTORY"] {
            let diagnostic = SpeechStreamDiagnostic(
                model: "gemini-3.1-flash-tts-preview",
                transcript: transcript,
                sampleRate: 24_000,
                channelCount: 1,
                bytesPerSample: 2,
                chunks: trace
            )
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try pcm.write(to: directoryURL.appending(path: "gemini-tts-stream.pcm"))
            try Self.wavData(from: pcm).write(
                to: directoryURL.appending(path: "gemini-tts-stream.wav")
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(diagnostic).write(
                to: directoryURL.appending(path: "gemini-tts-stream.json")
            )
            print("SpeechKit diagnostics: \(directoryURL.path())")
        }
    }
}

private extension SpeechSynthesisIntegrationTests {
    static func wavData(from pcm: Data) -> Data {
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(24_000))
        wav.appendLittleEndian(UInt32(48_000))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private struct SpeechStreamDiagnostic: Encodable {
    struct Chunk: Encodable {
        let index: Int
        let byteCount: Int
        let elapsedSeconds: Double
        let deliveryGapSeconds: Double
        let cumulativeAudioSeconds: Double
    }

    let model: String
    let transcript: String
    let sampleRate: Int
    let channelCount: Int
    let bytesPerSample: Int
    let chunks: [Chunk]
    let totalAudioSeconds: Double
    let totalDeliverySeconds: Double
    let audioPerDeliverySecond: Double

    init(
        model: String,
        transcript: String,
        sampleRate: Int,
        channelCount: Int,
        bytesPerSample: Int,
        chunks: [Chunk]
    ) {
        self.model = model
        self.transcript = transcript
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerSample = bytesPerSample
        self.chunks = chunks
        totalAudioSeconds = chunks.last?.cumulativeAudioSeconds ?? 0
        totalDeliverySeconds = chunks.last?.elapsedSeconds ?? 0
        audioPerDeliverySecond = totalDeliverySeconds > 0
            ? totalAudioSeconds / totalDeliverySeconds
            : 0
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private extension Data {
    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
