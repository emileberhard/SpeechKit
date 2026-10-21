import AVFoundation
import Foundation
import Testing

enum FixtureAudio {
    static func pcm16(_ fileName: String, sampleRate: Int) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Transcription/Fixtures/Audio/\(fileName)")
        let file = try AVAudioFile(forReading: url)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: input.format, to: format))
        let frameCount = Int((Double(input.frameLength) * Double(sampleRate) / input.format.sampleRate).rounded(.up)) + 1_024
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        let source = FixtureConversionSource(buffer: input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in source.next(status) }
        if let error { throw error }
        #expect(status != .error)
        let bytes = try #require(output.int16ChannelData)
        return Data(bytes: bytes[0], count: Int(output.frameLength) * 2)
    }
}

// AVAudioConverter invokes the input block synchronously; the lock additionally
// makes its one-time handoff explicit to Swift's @Sendable callback boundary.
private final class FixtureConversionSource: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}
