import AVFAudio
import Foundation

enum PCM16AudioEncoder {
    static func data(pcm16From input: FileHandle, byteCount: Int, sampleRate: Int,
                     fileExtension: String, settings: [String: Any]) throws -> Data {
        try data(byteCount: byteCount, sampleRate: sampleRate, fileExtension: fileExtension, settings: settings) { count in
            guard let chunk = try input.read(upToCount: count), chunk.count == count else {
                throw SpeechKitError.invalidRequest("Recording audio ended before its expected length")
            }
            return chunk
        }
    }

    static func data(byteCount: Int, sampleRate: Int, fileExtension: String,
                     settings: [String: Any], read: (Int) throws -> Data) throws -> Data {
        guard sampleRate > 0, byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw SpeechKitError.invalidRequest("Encoding requires nonempty PCM16 audio and a positive sample rate")
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = settings
        settings[AVSampleRateKey] = Double(sampleRate)
        settings[AVNumberOfChannelsKey] = 1
        try write(byteCount: byteCount, to: url, settings: settings, read: read)
        return try Data(contentsOf: url)
    }

    private static func write(byteCount: Int, to url: URL, settings: [String: Any], read: (Int) throws -> Data) throws {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
              let channel = buffer.int16ChannelData?[0] else {
            throw SpeechKitError.invalidRequest("Audio export could not allocate a PCM16 buffer")
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
