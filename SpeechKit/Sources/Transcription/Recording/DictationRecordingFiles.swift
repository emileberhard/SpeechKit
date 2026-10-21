import Foundation
import os

enum DictationRecordingFormat {
    static let version = 1
    static let manifestFileName = "recording.json"
    static let audioFileName = "audio.pcm"

    static func folder(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func encode<Owner>(_ manifest: DictationRecordingManifest<Owner>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: data)
    }
}

package struct DictationRecordingManifest<Owner: Codable & Sendable>: Codable, Sendable {
    let formatVersion: Int
    let id: UUID
    let startedAt: Date
    let sampleRate: Int
    let owner: Owner
    var finishedAt: Date?

    package init(formatVersion: Int, id: UUID, startedAt: Date, sampleRate: Int, owner: Owner, finishedAt: Date?) {
        self.formatVersion = formatVersion
        self.id = id
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.owner = owner
        self.finishedAt = finishedAt
    }
}

struct DictationRecordingManifestHeader: Decodable {
    let formatVersion: Int
    let startedAt: Date
    let sampleRate: Int
    let finishedAt: Date?
}

struct DictationRecordingManifestOwner<Owner: Decodable>: Decodable {
    let owner: Owner
}

enum DictationRecordingInventory {
    private static let lock = OSAllocatedUnfairLock()

    static func withLock<Result: Sendable>(_ body: @Sendable () throws -> Result) rethrows -> Result {
        try lock.withLock(body)
    }
}

enum OpenDictationRecordings {
    private static let ids = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    static func insert(_ id: UUID) {
        ids.withLock { _ = $0.insert(id) }
    }

    static func remove(_ id: UUID) {
        ids.withLock { _ = $0.remove(id) }
    }

    static func snapshot() -> Set<UUID> {
        ids.withLock { $0 }
    }
}

struct RecordingFileStatus {
    let byteCount: Int
    let modifiedAt: Date
}

package enum RecordingFileSystem {
    private static let logger = Logger(subsystem: "SpeechKit", category: "DictationRecordingStore")

    package static func prepareStoreDirectory(_ directory: URL) throws {
        try createProtectedDirectory(directory)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }

    package static func createProtectedDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
    }

    package static func createAppendOnlyFile(_ url: URL) throws -> Int32 {
        let descriptor = try withPath(url) {
            try check(Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, mode_t(0o600)))
        }
        do {
            try protect(url)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    package static func replaceFile(_ destination: URL, with data: Data) throws {
        let folder = destination.deletingLastPathComponent()
        let temporary = folder.appending(path: "\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            let descriptor = try createAppendOnlyFile(temporary)
            defer { Darwin.close(descriptor) }
            try write(data, to: descriptor)
            try sync(descriptor)
            try withPath(temporary) { source in
                try withPath(destination) { target in
                    _ = try check(Darwin.rename(source, target))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try syncDirectory(folder)
    }

    package static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0 {
                    guard errno == EINTR else { throw posixError() }
                    continue
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                address += written
                remaining -= written
            }
        }
    }

    package static func sync(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else { throw posixError() }
        }
    }

    package static func syncDirectory(_ directory: URL) throws {
        let descriptor = try withPath(directory) { try check(Darwin.open($0, O_RDONLY | O_CLOEXEC)) }
        defer { Darwin.close(descriptor) }
        try sync(descriptor)
    }

    static func status(_ url: URL) throws -> RecordingFileStatus? {
        var status = stat()
        let failure = try withPath(url) { path -> POSIXError? in
            Darwin.lstat(path, &status) == 0 ? nil : posixError()
        }
        switch failure {
        case nil:
            let modified = status.st_mtimespec
            return RecordingFileStatus(
                byteCount: Int(status.st_size),
                modifiedAt: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)
            )
        case let error? where error.code == .ENOENT:
            return nil
        case let error?:
            throw error
        }
    }

    package static func remove(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            guard isMissing(error) else { throw error }
        }
    }

    package static func removeAsHousekeeping(_ url: URL, id: UUID) {
        do {
            try remove(url)
        } catch {
            let error = error as NSError
            logger.error("Could not delete dictation recording \(id.uuidString, privacy: .public): \(error.domain, privacy: .public) \(error.code, privacy: .public)")
        }
    }

    package static func logWriteFailure(_ error: any Error, id: UUID) {
        let error = error as NSError
        logger.error("Could not save dictation audio for recording \(id.uuidString, privacy: .public); later audio is not saved: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    package static func logInventoryFailure(_ error: any Error) {
        let error = error as NSError
        logger.error("Could not prune dictation recordings: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    package static func isMissing(_ error: any Error) -> Bool {
        switch error {
        case let error as CocoaError:
            return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        case let error as POSIXError:
            return error.code == .ENOENT
        default:
            return false
        }
    }

    private static func protect(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        #endif
    }

    private static func withPath<Result>(
        _ url: URL,
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) throws -> Result {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw SpeechKitError.invalidRequest("Recording path has no file system representation")
            }
            return try body(path)
        }
    }

    private static func check(_ result: Int32) throws -> Int32 {
        guard result >= 0 else { throw posixError() }
        return result
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
