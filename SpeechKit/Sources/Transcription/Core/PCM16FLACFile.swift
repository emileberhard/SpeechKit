import AVFAudio
import Foundation

public enum PCM16FLACFile {
    public static func data(pcmData: Data, sampleRate: Int) throws -> Data {
        var offset = 0
        return try encode(byteCount: pcmData.count, sampleRate: sampleRate) { count in
            let chunk = pcmData.subdata(in: offset..<(offset + count))
            offset += count
            return chunk
        }
    }

    static func data(pcm16From input: FileHandle, byteCount: Int, sampleRate: Int) throws -> Data {
        try encode(byteCount: byteCount, sampleRate: sampleRate) { count in
            guard let chunk = try input.read(upToCount: count), chunk.count == count else {
                throw SpeechKitError.invalidRequest("Recording audio ended before its expected length")
            }
            return chunk
        }
    }

    private static func encode(byteCount: Int, sampleRate: Int, read: (Int) throws -> Data) throws -> Data {
        guard sampleRate > 0, byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw SpeechKitError.invalidRequest("FLAC encoding requires nonempty PCM16 audio and a positive sample rate")
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(byteCount: byteCount, sampleRate: sampleRate, to: url, read: read)
        return try Data(contentsOf: url)
    }

    private static func write(byteCount: Int, sampleRate: Int, to url: URL, read: (Int) throws -> Data) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ], commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let channel = buffer.int16ChannelData?[0] else {
            throw SpeechKitError.invalidRequest("FLAC export could not allocate a PCM16 buffer")
        }
        try withExtendedLifetime(file) {
            var remaining = byteCount
            while remaining > 0 {
                let requested = min(Int(buffer.frameCapacity) * MemoryLayout<Int16>.size, remaining)
                try autoreleasepool {
                    let chunk = try read(requested)
                    chunk.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            UnsafeMutableRawPointer(channel).copyMemory(from: base, byteCount: requested)
                        }
                    }
                    buffer.frameLength = AVAudioFrameCount(requested / MemoryLayout<Int16>.size)
                    try file.write(from: buffer)
                }
                remaining -= requested
            }
        }
    }
}
