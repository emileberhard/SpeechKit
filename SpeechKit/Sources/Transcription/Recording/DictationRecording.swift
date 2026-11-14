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

    @concurrent public func flacAudio(maximumByteCount: Int) async throws -> TranscriptionAudio {
        guard maximumByteCount > 0 else {
            throw SpeechKitError.invalidRequest("Maximum transcription audio size must be > 0")
        }
        let byteCount = try savedPCMByteCount()
        let input = try whileRecordingExists { try FileHandle(forReadingFrom: audioURL) }
        defer { try? input.close() }
        let data = try PCM16FLACFile.data(pcm16From: input, byteCount: byteCount, sampleRate: sampleRate)
        guard data.count <= maximumByteCount else {
            throw DictationRecordingError.audioTooLarge(byteCount: data.count, maximumByteCount: maximumByteCount)
        }
        return try TranscriptionAudio(data: data, fileName: "dictation.flac", mimeType: "audio/flac", fileExtension: "flac")
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
            return "The recording is \(byteCount) bytes after encoding, above the \(maximumByteCount)-byte limit"
        case .recordingMissing(let id):
            return "Dictation recording \(id.uuidString) no longer exists"
        case .alreadyFinished:
            return "The dictation recording is already finished"
        }
    }
}

enum PCM16AACEncoder {
    static func m4aData(pcm16From input: FileHandle, byteCount: Int, sampleRate: Int) throws -> Data {
        try PCM16AudioEncoder.data(pcm16From: input, byteCount: byteCount, sampleRate: sampleRate,
            fileExtension: "m4a", settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 32_000])
    }
}
