import Foundation

public enum PCM16WAVFile {
    static let headerByteCount = 44

    public static func data(pcmData: Data, sampleRate: Int) throws -> Data {
        guard sampleRate > 0 else {
            throw SpeechKitError.invalidRequest("PCM sample rate must be > 0")
        }
        guard !pcmData.isEmpty else {
            throw SpeechKitError.invalidRequest("PCM audio is empty")
        }

        guard pcmData.count <= Int(UInt32.max) - 36,
              sampleRate <= Int(UInt32.max) / MemoryLayout<Int16>.size else {
            throw SpeechKitError.invalidRequest("PCM audio exceeds WAV format limits")
        }
        var data = header(sampleRate: sampleRate, dataByteCount: UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }

    /// Use only for providers verified to accept the unknown-length WAV convention.
    static func streamingHeader(sampleRate: Int) throws -> Data {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max) / MemoryLayout<Int16>.size else {
            throw SpeechKitError.invalidRequest("PCM sample rate is outside WAV format limits")
        }
        return header(sampleRate: sampleRate, dataByteCount: .max)
    }

    private static func header(sampleRate: Int, dataByteCount: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(dataByteCount == .max ? .max : 36 + dataByteCount)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(MemoryLayout<Int16>.size))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
