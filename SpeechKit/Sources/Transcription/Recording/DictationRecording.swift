import AVFAudio
import Foundation

public struct DictationRecording<Owner: Codable & Sendable>: Sendable, Identifiable {
    public let id: UUID
    public let owner: Owner
    public let startedAt: Date
    public let duration: Duration
    public let wasInterrupted: Bool

    private let sampleRate: Int
    private let audioURL: URL

    init(
        id: UUID,
        owner: Owner,
        startedAt: Date,
        sampleRate: Int,
        wasInterrupted: Bool,
        audioURL: URL,
        audioByteCount: Int
    ) {
        self.id = id
        self.owner = owner
        self.startedAt = startedAt
        self.duration = .seconds(audioByteCount / MemoryLayout<Int16>.size) / sampleRate
        self.wasInterrupted = wasInterrupted
        self.sampleRate = sampleRate
        self.audioURL = audioURL
    }

    @concurrent public func transcriptionAudio(maximumByteCount: Int) async throws -> TranscriptionAudio {
        guard maximumByteCount > 0 else {
            throw SpeechKitError.invalidRequest("Maximum transcription audio size must be > 0")
        }
        let pcmByteCount = try savedPCMByteCount()
        guard pcmByteCount > 0 else {
            throw SpeechKitError.invalidRequest("PCM audio is empty")
        }
        if PCM16WAVFile.headerByteCount + pcmByteCount <= maximumByteCount {
            let pcm = try whileRecordingExists { try Data(contentsOf: audioURL, options: .mappedIfSafe) }
            let wav = try PCM16WAVFile.data(pcmData: pcm.prefix(pcmByteCount), sampleRate: sampleRate)
            return try TranscriptionAudio(data: wav, fileName: "dictation.wav", mimeType: "audio/wav", fileExtension: "wav")
        }
        let input = try whileRecordingExists { try FileHandle(forReadingFrom: audioURL) }
        defer { try? input.close() }
        let aac = try PCM16AACEncoder.m4aData(pcm16From: input, byteCount: pcmByteCount, sampleRate: sampleRate)
        guard aac.count <= maximumByteCount else {
            throw DictationRecordingError.audioTooLarge(byteCount: aac.count, maximumByteCount: maximumByteCount)
        }
        return try TranscriptionAudio(data: aac, fileName: "dictation.m4a", mimeType: "audio/m4a", fileExtension: "m4a")
    }

    private func savedPCMByteCount() throws -> Int {
        guard let status = try RecordingFileSystem.status(audioURL) else {
            throw DictationRecordingError.recordingMissing(id)
        }
        return status.byteCount - status.byteCount % MemoryLayout<Int16>.size
    }

    private func whileRecordingExists<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch {
            guard RecordingFileSystem.isMissing(error) else { throw error }
            throw DictationRecordingError.recordingMissing(id)
        }
    }
}

public struct IncompleteDictationRecording<Owner: Codable & Sendable>: Error {
    public let recording: DictationRecording<Owner>
    public let cause: any Error
}

extension IncompleteDictationRecording: LocalizedError {
    public var errorDescription: String? {
        "Only part of the dictation was saved: \(cause.localizedDescription)"
    }
}

public enum DictationRecordingError: Error, Sendable, Equatable {
    case audioTooLarge(byteCount: Int, maximumByteCount: Int)
    case recordingMissing(UUID)
    case alreadyFinished
}

extension DictationRecordingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .audioTooLarge(let byteCount, let maximumByteCount):
            return "The recording is \(byteCount) bytes even as AAC, above the \(maximumByteCount)-byte limit"
        case .recordingMissing(let id):
            return "Dictation recording \(id.uuidString) no longer exists"
        case .alreadyFinished:
            return "The dictation recording is already finished"
        }
    }
}

enum PCM16AACEncoder {
    private static let bitRate = 32_000
    private static let framesPerBuffer: AVAudioFrameCount = 16_384

    static func m4aData(pcm16From input: FileHandle, byteCount: Int, sampleRate: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try encode(byteCount, from: input, sampleRate: sampleRate, to: url)
        return try Data(contentsOf: url)
    }

    private static func encode(_ byteCount: Int, from input: FileHandle, sampleRate: Int, to url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerBuffer),
              let channel = buffer.int16ChannelData?[0] else {
            throw SpeechKitError.invalidRequest("AAC export could not allocate a PCM16 buffer")
        }
        let bytesPerBuffer = Int(framesPerBuffer) * MemoryLayout<Int16>.size
        try withExtendedLifetime(file) {
            var remaining = byteCount
            while remaining > 0 {
                let requested = min(bytesPerBuffer, remaining)
                try autoreleasepool {
                    guard let chunk = try input.read(upToCount: requested), chunk.count == requested else {
                        throw SpeechKitError.invalidRequest("Recording audio ended before its expected length")
                    }
                    chunk.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return }
                        UnsafeMutableRawPointer(channel).copyMemory(from: base, byteCount: requested)
                    }
                    buffer.frameLength = AVAudioFrameCount(requested / MemoryLayout<Int16>.size)
                    try file.write(from: buffer)
                }
                remaining -= requested
            }
        }
    }
}
