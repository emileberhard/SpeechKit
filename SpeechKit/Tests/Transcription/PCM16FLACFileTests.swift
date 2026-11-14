import AVFAudio
import Foundation
import Testing
@testable import SpeechKit

struct PCM16FLACFileTests {
    @Test func losslessExportPreservesEverySampleAcrossEncoderChunks() throws {
        let samples = (0..<70_123).map { Int16(truncatingIfNeeded: $0 &* 173) }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let data = try PCM16FLACFile.data(pcmData: pcm, sampleRate: 16_000)
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        #expect(file.processingFormat.sampleRate == 16_000)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length == samples.count)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        try file.read(into: buffer)
        let channel = try #require(buffer.int16ChannelData?[0])
        #expect(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) == samples)
    }

    @Test func aShortRecordingFailsRatherThanEncodingAnIncompletePrefix() throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID()).pcm")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2]).write(to: url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        #expect(throws: SpeechKitError.self) {
            try PCM16AudioEncoder.data(pcm16From: input, byteCount: 4, sampleRate: 16_000,
                fileExtension: "flac", settings: [AVFormatIDKey: kAudioFormatFLAC])
        }
    }

    @Test(arguments: [(Data(), 16_000), (Data([1]), 16_000), (Data([1, 2]), 0)])
    func invalidPCMIsRejected(pcm: Data, sampleRate: Int) {
        #expect(throws: SpeechKitError.self) { try PCM16FLACFile.data(pcmData: pcm, sampleRate: sampleRate) }
    }
}
