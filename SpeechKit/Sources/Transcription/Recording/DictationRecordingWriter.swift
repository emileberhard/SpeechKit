import Foundation
import os

public final class DictationRecordingWriter<Owner: Codable & Sendable>: Sendable {
    private enum Phase: Sendable {
        case recording(descriptor: Int32)
        case failed(descriptor: Int32, error: any Error)
        case closed
    }

    private struct State: Sendable {
        var phase: Phase
        var audioByteCount = 0
        var unsyncedByteCount = 0
    }

    public var id: UUID { manifest.id }

    private let manifest: DictationRecordingManifest<Owner>
    private let folder: URL
    private let state: OSAllocatedUnfairLock<State>

    package static func start(
        manifest: DictationRecordingManifest<Owner>,
        in storeDirectory: URL
    ) throws -> DictationRecordingWriter<Owner> {
        let encodedManifest = try DictationRecordingFormat.encode(manifest)
        let folder = DictationRecordingFormat.folder(for: manifest.id, in: storeDirectory)
        OpenDictationRecordings.insert(manifest.id)
        let descriptor: Int32
        do {
            try RecordingFileSystem.createProtectedDirectory(folder)
            try RecordingFileSystem.syncDirectory(storeDirectory)
            try RecordingFileSystem.replaceFile(
                folder.appending(path: DictationRecordingFormat.manifestFileName),
                with: encodedManifest
            )
            descriptor = try RecordingFileSystem.createAppendOnlyFile(
                folder.appending(path: DictationRecordingFormat.audioFileName)
            )
            do {
                try RecordingFileSystem.syncDirectory(folder)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            OpenDictationRecordings.remove(manifest.id)
            throw error
        }
        return DictationRecordingWriter(manifest: manifest, folder: folder, descriptor: descriptor)
    }

    private init(manifest: DictationRecordingManifest<Owner>, folder: URL, descriptor: Int32) {
        self.manifest = manifest
        self.folder = folder
        self.state = OSAllocatedUnfairLock(initialState: State(phase: .recording(descriptor: descriptor)))
    }

    deinit {
        let descriptor = state.withLock { state -> Int32? in
            switch state.phase {
            case .recording(let descriptor), .failed(let descriptor, _):
                state.phase = .closed
                return descriptor
            case .closed:
                return nil
            }
        }
        if let descriptor {
            Darwin.close(descriptor)
            OpenDictationRecordings.remove(manifest.id)
        }
    }

    public func append(_ pcm16: Data) {
        let bytesPerSecond = manifest.sampleRate * MemoryLayout<Int16>.size
        let failure = state.withLock { state -> (any Error)? in
            guard case .recording(let descriptor) = state.phase else { return nil }
            do {
                guard pcm16.count.isMultiple(of: MemoryLayout<Int16>.size) else {
                    throw SpeechKitError.invalidRequest("PCM16 chunks must contain complete samples")
                }
                try RecordingFileSystem.write(pcm16, to: descriptor)
                state.audioByteCount += pcm16.count
                state.unsyncedByteCount += pcm16.count
                if state.unsyncedByteCount >= bytesPerSecond {
                    try RecordingFileSystem.sync(descriptor)
                    state.unsyncedByteCount = 0
                }
                return nil
            } catch {
                state.phase = .failed(descriptor: descriptor, error: error)
                return error
            }
        }
        if let failure {
            RecordingFileSystem.logWriteFailure(failure, id: manifest.id)
        }
    }

    @concurrent public func finish() async throws -> DictationRecording<Owner> {
        let (descriptor, audioByteCount, failure) = try state.withLock { state -> (Int32, Int, (any Error)?) in
            switch state.phase {
            case .closed:
                throw DictationRecordingError.alreadyFinished
            case .recording(let descriptor):
                state.phase = .closed
                return (descriptor, state.audioByteCount, nil)
            case .failed(let descriptor, let error):
                state.phase = .closed
                return (descriptor, state.audioByteCount, error)
            }
        }
        defer {
            Darwin.close(descriptor)
            OpenDictationRecordings.remove(manifest.id)
        }
        try RecordingFileSystem.sync(descriptor)
        let audioURL = folder.appending(path: DictationRecordingFormat.audioFileName)
        if let failure {
            let savedByteCount = try RecordingFileSystem.status(audioURL).map { $0.byteCount - $0.byteCount % MemoryLayout<Int16>.size } ?? 0
            guard savedByteCount > 0 else { throw failure }
            throw IncompleteDictationRecording(
                recording: recording(wasInterrupted: true, audioURL: audioURL, audioByteCount: savedByteCount),
                cause: failure
            )
        }

        var finished = manifest
        finished.finishedAt = Date()
        try RecordingFileSystem.replaceFile(
            folder.appending(path: DictationRecordingFormat.manifestFileName),
            with: DictationRecordingFormat.encode(finished)
        )
        return recording(wasInterrupted: false, audioURL: audioURL, audioByteCount: audioByteCount)
    }

    private func recording(wasInterrupted: Bool, audioURL: URL, audioByteCount: Int) -> DictationRecording<Owner> {
        DictationRecording(
            id: manifest.id,
            owner: manifest.owner,
            startedAt: manifest.startedAt,
            sampleRate: manifest.sampleRate,
            wasInterrupted: wasInterrupted,
            audioURL: audioURL,
            audioByteCount: audioByteCount
        )
    }

    @concurrent public func discard() async throws {
        let descriptor = try state.withLock { state -> Int32 in
            switch state.phase {
            case .closed:
                throw DictationRecordingError.alreadyFinished
            case .recording(let descriptor), .failed(let descriptor, _):
                state.phase = .closed
                return descriptor
            }
        }
        Darwin.close(descriptor)
        defer { OpenDictationRecordings.remove(manifest.id) }
        try RecordingFileSystem.remove(folder)
    }
}
