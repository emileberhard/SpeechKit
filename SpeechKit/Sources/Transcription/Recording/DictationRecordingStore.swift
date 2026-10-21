import Foundation

public struct DictationRecordingRetention: Sendable {
    let maximumCount: Int
    let maximumAge: Duration

    public init(maximumCount: Int, maximumAge: Duration) throws {
        guard maximumCount >= 1 else {
            throw SpeechKitError.invalidConfiguration("Dictation recording retention must keep at least one recording")
        }
        guard maximumAge > .zero else {
            throw SpeechKitError.invalidConfiguration("Dictation recording retention needs a positive maximum age")
        }
        self.maximumCount = maximumCount
        self.maximumAge = maximumAge
    }
}

public struct DictationRecordingStore<Owner: Codable & Sendable>: Sendable {
    private struct Inventory {
        var saved: [SavedRecording] = []
        var withoutAudio: [(id: UUID, folder: URL)] = []
        var openCount = 0
    }

    private struct SavedRecording {
        let id: UUID
        let folder: URL
        let startedAt: Date
        let listing: DictationRecording<Owner>?
    }

    private let directory: URL
    private let retention: DictationRecordingRetention

    public init(directory: URL, retention: DictationRecordingRetention) {
        self.directory = directory
        self.retention = retention
    }

    @concurrent public func startRecording(owner: Owner, sampleRate: Int) async throws -> DictationRecordingWriter<Owner> {
        try await startRecording(id: UUID(), owner: owner, sampleRate: sampleRate)
    }

    @concurrent public func startRecording(id: UUID, owner: Owner, sampleRate: Int) async throws -> DictationRecordingWriter<Owner> {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max) / MemoryLayout<Int16>.size else {
            throw SpeechKitError.invalidRequest("Recording sample rate is outside WAV format limits")
        }
        let manifest = DictationRecordingManifest(
            formatVersion: DictationRecordingFormat.version,
            id: id,
            startedAt: Date(),
            sampleRate: sampleRate,
            owner: owner,
            finishedAt: nil
        )
        return try DictationRecordingInventory.withLock {
            try RecordingFileSystem.prepareStoreDirectory(directory)
            guard !FileManager.default.fileExists(atPath: DictationRecordingFormat.folder(for: id, in: directory).path) else {
                throw SpeechKitError.invalidRequest("A dictation recording with this identity already exists")
            }
            let writer = try DictationRecordingWriter.start(manifest: manifest, in: directory)
            do {
                _ = prune(try inventory())
            } catch {
                RecordingFileSystem.logInventoryFailure(error)
            }
            return writer
        }
    }

    @concurrent public func recordings() async throws -> [DictationRecording<Owner>] {
        try DictationRecordingInventory.withLock {
            prune(try inventory())
        }
    }

    @concurrent public func discard(_ recording: DictationRecording<Owner>) async throws {
        try RecordingFileSystem.remove(DictationRecordingFormat.folder(for: recording.id, in: directory))
    }

    private func prune(_ inventory: Inventory) -> [DictationRecording<Owner>] {
        for (id, folder) in inventory.withoutAudio {
            RecordingFileSystem.removeAsHousekeeping(folder, id: id)
        }
        let oldestRetainedStart = Date().addingTimeInterval(-retention.maximumAge.timeInterval)
        var retained: [SavedRecording] = []
        for recording in inventory.saved {
            guard recording.startedAt >= oldestRetainedStart else {
                RecordingFileSystem.removeAsHousekeeping(recording.folder, id: recording.id)
                continue
            }
            retained.append(recording)
        }
        retained.sort { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
        let capacity = max(0, retention.maximumCount - inventory.openCount)
        for recording in retained.dropFirst(capacity) {
            RecordingFileSystem.removeAsHousekeeping(recording.folder, id: recording.id)
        }
        return retained.prefix(capacity).compactMap(\.listing)
    }

    private func inventory() throws -> Inventory {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            guard RecordingFileSystem.isMissing(error) else { throw error }
            return Inventory()
        }
        let open = OpenDictationRecordings.snapshot()
        var inventory = Inventory()
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            guard !open.contains(id) else {
                inventory.openCount += 1
                continue
            }
            if let recording = try savedRecording(id: id, folder: entry) {
                inventory.saved.append(recording)
            } else {
                inventory.withoutAudio.append((id, entry))
            }
        }
        return inventory
    }

    private func savedRecording(id: UUID, folder: URL) throws -> SavedRecording? {
        let audioURL = folder.appending(path: DictationRecordingFormat.audioFileName)
        guard let audio = try RecordingFileSystem.status(audioURL) else { return nil }
        let audioByteCount = audio.byteCount - audio.byteCount % MemoryLayout<Int16>.size
        guard audioByteCount > 0 else { return nil }
        guard let manifest = try readManifest(in: folder),
              let header = try? DictationRecordingFormat.decode(DictationRecordingManifestHeader.self, from: manifest),
              header.sampleRate > 0 else {
            return SavedRecording(id: id, folder: folder, startedAt: audio.modifiedAt, listing: nil)
        }
        let owner = header.formatVersion == DictationRecordingFormat.version
            ? try? DictationRecordingFormat.decode(DictationRecordingManifestOwner<Owner>.self, from: manifest).owner
            : nil
        return SavedRecording(
            id: id,
            folder: folder,
            startedAt: header.startedAt,
            listing: owner.map { owner in
                DictationRecording(
                    id: id,
                    owner: owner,
                    startedAt: header.startedAt,
                    sampleRate: header.sampleRate,
                    wasInterrupted: header.finishedAt == nil,
                    audioURL: audioURL,
                    audioByteCount: audioByteCount
                )
            }
        )
    }

    private func readManifest(in folder: URL) throws -> Data? {
        do {
            return try Data(contentsOf: folder.appending(path: DictationRecordingFormat.manifestFileName))
        } catch {
            guard RecordingFileSystem.isMissing(error) else { throw error }
            return nil
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
