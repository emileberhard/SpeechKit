import AVFAudio
import Foundation

public enum PCM16FLACFile {
    public static func data(pcmData: Data, sampleRate: Int) throws -> Data {
        var offset = 0
        return try PCM16AudioEncoder.data(byteCount: pcmData.count, sampleRate: sampleRate,
            fileExtension: "flac", settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 16]) { count in
            let chunk = pcmData.subdata(in: offset..<(offset + count))
            offset += count
            return chunk
        }
    }

    static func data(pcm16From input: FileHandle, byteCount: Int, sampleRate: Int) throws -> Data {
        try PCM16AudioEncoder.data(pcm16From: input, byteCount: byteCount, sampleRate: sampleRate,
            fileExtension: "flac", settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 16])
    }
}
