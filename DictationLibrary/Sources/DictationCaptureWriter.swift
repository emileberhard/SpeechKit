import AudioToolbox
import AVFAudio
import Foundation
import os
import SpeechKit

public struct IncompleteLibraryCapture: Error, Sendable {
    public let capture: DictationCapture
    public let cause: any Error
}

final class LibraryCapacity: Sendable {
    private let used: OSAllocatedUnfairLock<Int64>
    let limit: Int64

    init(limit: Int64, used: Int64) {
        self.limit = limit
        self.used = OSAllocatedUnfairLock(initialState: used)
    }

    var usedBytes: Int64 { used.withLock { $0 } }

    func reserve(_ count: Int64) throws {
        try used.withLock { used in
            guard count >= 0, count <= limit - used else { throw DictationLibraryError.capacityExceeded(limit: limit, used: used) }
            used += count
        }
    }

    func requireHeadroom(_ count: Int64) throws {
        try used.withLock { used in
            guard count <= limit - used else { throw DictationLibraryError.capacityExceeded(limit: limit, used: used) }
        }
    }

    func release(_ count: Int64) { used.withLock { $0 -= count } }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(LibraryFiles.encode(value), to: url)
    }

    func write(_ bytes: Data, to url: URL) throws {
        try RecordingFileSystem.createProtectedDirectory(url.deletingLastPathComponent())
        let previous = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let increase = Int64(bytes.count) - previous
        if increase > 0 { try reserve(increase) }
        do { try RecordingFileSystem.replaceFile(url, with: bytes) }
        catch {
            if increase > 0 { release(increase) }
            throw error
        }
        if increase < 0 { release(-increase) }
    }

    func remove(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        let bytes = values?.isDirectory == true ? try LibraryFiles(root: url).usedBytes() : Int64(values?.fileSize ?? 0)
        try RecordingFileSystem.remove(url)
        release(bytes)
    }
}

public final class DictationCaptureWriter: Sendable {
    private enum Phase { case recording, finishing, finished }

    private struct State {
        var capture: DictationCapture
        var journal: DictationRecordingWriter<DictationCapture>?
        var converter: AVAudioConverter?
        var format: AVAudioFormat?
        var byteCount: Int64 = 0
        var journalMetadataBytes: Int64 = 0
        var failure: (any Error)?
        var phase = Phase.recording
    }

    public let id: UUID
    public let plan: DictationPlan
    public let originalURL: URL
    private let folder: URL
    private let capacity: LibraryCapacity
    private let state: OSAllocatedUnfairLock<State>

    init(capture: DictationCapture, folder: URL, capacity: LibraryCapacity) throws {
        id = capture.id
        plan = capture.plan
        originalURL = folder.appending(path: "original.caf")
        self.folder = folder
        self.capacity = capacity
        state = OSAllocatedUnfairLock(uncheckedState: State(capture: capture))
        try capacity.write(capture, to: folder.appending(path: "capture.json"))
    }

    public func configure(format: AVAudioFormat) throws {
        try state.withLockUnchecked { state in
            guard state.phase == .recording, state.journal == nil else { throw DictationLibraryError.recordingFinished }
            guard format.sampleRate > 0, format.sampleRate <= 192_000,
                  let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: format.sampleRate, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: format, to: output) else { throw DictationLibraryError.invalidConfiguration }
            state.capture.sampleRate = Int(format.sampleRate)
            try capacity.write(state.capture, to: folder.appending(path: "capture.json"))
            let manifest = DictationRecordingManifest(formatVersion: 1, id: id, startedAt: state.capture.startedAt, sampleRate: Int(format.sampleRate), owner: state.capture, finishedAt: nil)
            let journalDirectory = folder.appending(path: "journal")
            try RecordingFileSystem.createProtectedDirectory(journalDirectory)
            let metadataBytes = Int64(try LibraryFiles.encode(manifest).count) + 64
            try capacity.reserve(metadataBytes)
            do { state.journal = try DictationRecordingWriter.start(manifest: manifest, in: journalDirectory) }
            catch { capacity.release(metadataBytes); throw error }
            state.journalMetadataBytes = metadataBytes
            state.format = format
            state.converter = converter
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        state.withLockUnchecked { state in
            guard state.phase == .recording, state.failure == nil else { return }
            do {
                guard state.format == buffer.format, let converter = state.converter, let journal = state.journal,
                      let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: buffer.frameLength + 64) else {
                    throw DictationLibraryError.invalidConfiguration
                }
                nonisolated(unsafe) let input = buffer
                nonisolated(unsafe) var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, status in
                    guard !supplied else { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return input
                }
                if let error { throw error }
                guard status != .error, let samples = output.int16ChannelData?[0] else { throw DictationLibraryError.invalidConfiguration }
                let count = Int(output.frameLength) * MemoryLayout<Int16>.size
                try capacity.reserve(Int64(count))
                journal.append(Data(bytes: samples, count: count))
                state.byteCount += Int64(count)
            } catch { state.failure = error }
        }
    }

    var isFinished: Bool { state.withLockUnchecked { $0.phase == .finished } }

    @concurrent public func finish() async throws -> DictationCapture {
        var (capture, journal, count, metadataBytes, failure) = try state.withLockUnchecked { state in
            guard state.phase == .recording else { throw DictationLibraryError.recordingFinished }
            state.phase = .finishing
            return (state.capture, state.journal, state.byteCount, state.journalMetadataBytes, state.failure)
        }
        defer { state.withLockUnchecked { $0.phase = .finished } }
        guard let journal, count > 0, let rate = capture.sampleRate else {
            if let journal { try await journal.discard(); capacity.release(metadataBytes) }
            throw failure ?? DictationLibraryError.noAudio
        }
        do { _ = try await journal.finish() }
        catch let incomplete as IncompleteDictationRecording<DictationCapture> { failure = incomplete.cause }
        catch { failure = error }
        let actualMetadataBytes = Int64(try folder.appending(path: "journal/\(id.uuidString)/recording.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        if metadataBytes > actualMetadataBytes { capacity.release(metadataBytes - actualMetadataBytes) }
        metadataBytes = actualMetadataBytes
        let pcm = folder.appending(path: "journal/\(id.uuidString)/audio.pcm")
        capture.interrupted = failure != nil
        capture.finishedAt = .now
        do {
            let original = originalURL
            try OpusOriginal.seal(pcm: pcm, sampleRate: rate, destination: original, capacity: capacity)
            capture.originalSHA256 = try LibraryFiles.hashFile(original)
            capture.originalByteCount = Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try capacity.write(capture, to: folder.appending(path: "capture.json"))
            try RecordingFileSystem.remove(folder.appending(path: "journal"))
            capacity.release(count + metadataBytes)
        } catch {
            capture.interrupted = true
            try capacity.write(capture, to: folder.appending(path: "capture.json"))
            throw IncompleteLibraryCapture(capture: capture, cause: error)
        }
        if let failure { throw IncompleteLibraryCapture(capture: capture, cause: failure) }
        return capture
    }
}

enum OpusOriginal {
    static func seal(pcm: URL, sampleRate: Int, destination: URL, capacity: LibraryCapacity) throws {
        let byteCount = Int64(try pcm.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard byteCount >= 2 else { throw DictationLibraryError.noAudio }
        let encodedBytesPerSecond = 16_000.0
        let estimate = Int64(Double(byteCount) / Double(2 * sampleRate) * encodedBytesPerSecond)
        let reserve = min(byteCount, estimate) + 131_072
        try capacity.reserve(reserve)
        var reserved = reserve
        defer { capacity.release(reserved) }
        let temporary = destination.appendingPathExtension("sealing")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(temporary as CFURL, kAudioFileCAFType, &format, nil, AudioFileFlags.eraseFile.rawValue, &created))
        guard let file = created else { throw DictationLibraryError.invalidConfiguration }
        var disposed = false
        defer { if !disposed { ExtAudioFileDispose(file) } }
        var audioFile: AudioFileID?
        var size = UInt32(MemoryLayout<AudioFileID?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile))
        guard let audioFile else { throw DictationLibraryError.invalidConfiguration }
        var zero: Float64 = 0
        try check(AudioFileSetProperty(audioFile, kAudioFilePropertyReserveDuration, UInt32(MemoryLayout<Float64>.size), &zero))
        guard let client = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true) else { throw DictationLibraryError.invalidConfiguration }
        var clientDescription = client.streamDescription.pointee
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientDescription))
        var converter: AudioConverterRef?
        size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { throw DictationLibraryError.invalidConfiguration }
        var bitRate: UInt32 = 96_000
        try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitRate))
        let input = try FileHandle(forReadingFrom: pcm)
        defer { try? input.close() }
        while let bytes = try input.read(upToCount: 32_768), bytes.count >= 2 {
            try bytes.withUnsafeBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count - bytes.count % 2), mData: UnsafeMutableRawPointer(mutating: raw.baseAddress)))
                try check(ExtAudioFileWrite(file, UInt32(bytes.count / 2), &list))
            }
        }
        let status = ExtAudioFileDispose(file)
        disposed = true
        try check(status)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        let actual = Int64(try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard actual <= reserve else { throw DictationLibraryError.capacityExceeded(limit: capacity.limit, used: actual) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        try RecordingFileSystem.syncDirectory(destination.deletingLastPathComponent())
        reserved -= actual
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
