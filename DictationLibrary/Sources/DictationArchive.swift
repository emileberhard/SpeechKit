import CloudKit
import CryptoKit
import Foundation
import SpeechKit

public struct DictationCatchUpReport: Equatable, Sendable {
    public let newCaptureCount: Int
    public let newResultCount: Int
    public let cloudDeletionCount: Int
    public let problems: [String]
}

public struct DictationReplicationReport: Equatable, Sendable {
    public let fetchedCount: Int
    public let presentCount: Int
    public let failures: [UUID: String]
    public let capacityExceeded: Bool
}

public struct DictationRestorationReport: Equatable, Sendable {
    public let captureCount: Int
    public let resultCount: Int
    public let originalCount: Int
    public let missingOriginalCaptureIDs: [UUID]
}

public struct DictationExportManifest: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable { public let hash: String }
    public struct Freshness: Codable, Equatable, Sendable {
        public let lastCatchUpAt: Date?
        public let catchUpReachedEnd: Bool
    }
    public struct Completeness: Codable, Equatable, Sendable {
        public let captureCount: Int
        public let resultCount: Int
        public let audioPresentCount: Int
        public let missingAudioCaptureIDs: [UUID]
        public let problems: [String]
    }
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let byteCount: Int64
        public let sha256: String
    }

    public let formatVersion: Int
    public let account: Account
    public let createdAt: Date
    public let complete: Bool
    public let freshness: Freshness
    public let completeness: Completeness
    public let files: [File]
}

public struct DictationExport: Equatable, Sendable {
    public let directory: URL
    public let manifest: DictationExportManifest
}

public actor DictationArchive {
    private struct State: Codable {
        var token: Data?
        var lastCatchUpAt: Date?
        var reachedEnd = false
        var problems: [String] = []
    }

    static let retainedExportCount = 2
    static let manifestFormatVersion = 1
    private let files: LibraryFiles
    private let capacity: LibraryCapacity
    private let cloud: any LibraryCloud
    private let chunkBytes: Int
    private var downloads: [String: Task<URL, any Error>] = [:]

    public init(directory: URL, capacityBytes: Int64, containerIdentifier: String) throws {
        try self.init(directory: directory, capacityBytes: capacityBytes, cloud: CloudKitLibraryCloud(containerIdentifier: containerIdentifier))
    }

    init(directory: URL, capacityBytes: Int64, cloud: any LibraryCloud, chunkBytes: Int = DictationLibrarySchema.chunkBytes) throws {
        guard capacityBytes > 0 else { throw DictationLibraryError.invalidConfiguration }
        files = LibraryFiles(root: directory)
        self.cloud = cloud
        self.chunkBytes = chunkBytes
        try RecordingFileSystem.createProtectedDirectory(directory)
        capacity = LibraryCapacity(limit: capacityBytes, used: try files.usedBytes())
    }

    @discardableResult public func refresh() async throws -> DictationCatchUpReport {
        let account = try await verifiedAccount()
        let partition = files.partition(account)
        var state = try loadState(partition)
        var newCaptures = 0
        var newResults = 0
        var deletions = 0
        state.reachedEnd = false
        try write(state, to: partition.appending(path: "state.json"))
        while true {
            let page: LibraryCloudPage
            do { page = try await cloud.changes(since: state.token, desiredKeys: DictationLibrarySchema.metadataKeys) }
            catch LibraryCloudError.tokenExpired { state.token = nil; continue }
            catch LibraryCloudError.zoneMissing {
                guard state.token == nil else { throw DictationLibraryError.cloudDeletedRequiresDecision }
                break
            }
            guard try await cloud.accountIdentifier() == account else { throw DictationLibraryError.accountChanged }
            for record in page.records {
                switch try apply(record, in: partition) {
                case .newCapture: newCaptures += 1
                case .newResult: newResults += 1
                case .ignored, .unchanged: break
                }
            }
            deletions += page.deletedCount
            state.token = page.token
            try write(state, to: partition.appending(path: "state.json"))
            if !page.moreComing { break }
        }
        state.lastCatchUpAt = .now
        state.reachedEnd = true
        try write(state, to: partition.appending(path: "state.json"))
        return DictationCatchUpReport(newCaptureCount: newCaptures, newResultCount: newResults, cloudDeletionCount: deletions, problems: state.problems)
    }

    public func entries() async throws -> [DictationArchiveEntry] {
        let partition = files.partition(try await verifiedAccount())
        return try captures(in: partition).map { capture in
            let folder = captureFolder(capture.id, in: partition)
            let original = folder.appending(path: "original.caf")
            return try DictationArchiveEntry(capture: capture, results: results(in: folder), originalURL: FileManager.default.fileExists(atPath: original.path) ? original : nil, published: true)
        }.sorted { $0.capture.startedAt > $1.capture.startedAt }
    }

    public func addResult(_ result: DictationResultVersion, session: DictationAccountSession) throws {
        let account = session.accountIdentifier
        let partition = files.partition(account)
        let folder = captureFolder(result.captureID, in: partition)
        guard FileManager.default.fileExists(atPath: folder.appending(path: "capture.json").path) else { throw DictationLibraryError.invalidCapture(result.captureID) }
        let payload = try LibraryFiles.encode(result)
        let name = "\(result.id.uuidString).json"
        let existing = ["results", "outbox"].map { folder.appending(path: "\($0)/\(name)") }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let existing {
            guard try Data(contentsOf: existing) == payload else { throw DictationLibraryError.contentConflict(result.id.uuidString) }
        } else {
            let destination = folder.appending(path: "outbox/\(name)")
            try RecordingFileSystem.createProtectedDirectory(destination.deletingLastPathComponent())
            try write(payload, to: destination)
        }
    }

    public func publishPendingResults(session: DictationAccountSession) async throws {
        let account = try await verifiedAccount()
        guard account == session.accountIdentifier else { throw DictationLibraryError.accountChanged }
        let partition = files.partition(account)
        for capture in try captures(in: partition) {
            let folder = captureFolder(capture.id, in: partition)
            for result in try LibraryFiles.results(inDirectory: folder.appending(path: "outbox")) {
                let payload = try LibraryFiles.encode(result)
                guard try await cloud.accountIdentifier() == account else { throw DictationLibraryError.accountChanged }
                do { try await cloud.create(DictationLibrarySchema.record(type: DictationLibrarySchema.resultRecordType, name: DictationLibrarySchema.resultName(result.id), payload: payload, hash: LibraryFiles.hash(payload))) }
                catch let error as DictationLibraryError { throw error }
                catch { throw DictationLibraryError.cloudFailure("\((error as NSError).domain) \((error as NSError).code)") }
                guard try await cloud.accountIdentifier() == account else { throw DictationLibraryError.accountChanged }
                let pending = folder.appending(path: "outbox/\(result.id.uuidString).json")
                let confirmed = folder.appending(path: "results/\(result.id.uuidString).json")
                try RecordingFileSystem.createProtectedDirectory(confirmed.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: confirmed.path) {
                    guard try Data(contentsOf: confirmed) == payload else { throw DictationLibraryError.contentConflict(result.id.uuidString) }
                    try remove(pending)
                } else if FileManager.default.fileExists(atPath: pending.path) {
                    try FileManager.default.moveItem(at: pending, to: confirmed)
                } else {
                    try write(payload, to: confirmed)
                }
            }
        }
    }

    public func reseedPublication(session: DictationAccountSession) async throws -> DictationRestorationReport {
        let account = try await verifiedAccount()
        guard account == session.accountIdentifier else { throw DictationLibraryError.accountChanged }
        let partition = files.partition(account)
        var state = try loadState(partition)
        state.token = nil
        state.reachedEnd = false
        try write(state, to: partition.appending(path: "state.json"))
        var captureCount = 0
        var resultCount = 0
        var originalCount = 0
        var missing: [UUID] = []
        for capture in try captures(in: partition) {
            let folder = captureFolder(capture.id, in: partition)
            let payload = try Data(contentsOf: folder.appending(path: "capture.json"))
            try await restoreRecord(DictationLibrarySchema.record(type: DictationLibrarySchema.captureRecordType, name: DictationLibrarySchema.captureName(capture.id), payload: payload, hash: LibraryFiles.hash(payload)), account: account)
            captureCount += 1
            for result in try results(in: folder) {
                let pending = folder.appending(path: "outbox/\(result.id.uuidString).json")
                let confirmed = folder.appending(path: "results/\(result.id.uuidString).json")
                let data = try Data(contentsOf: FileManager.default.fileExists(atPath: pending.path) ? pending : confirmed)
                try await restoreRecord(DictationLibrarySchema.record(type: DictationLibrarySchema.resultRecordType, name: DictationLibrarySchema.resultName(result.id), payload: data, hash: LibraryFiles.hash(data)), account: account)
                resultCount += 1
            }
            let original = folder.appending(path: "original.caf")
            guard FileManager.default.fileExists(atPath: original.path) else { missing.append(capture.id); continue }
            guard try LibraryFiles.hashFile(original) == capture.originalSHA256 else { throw DictationLibraryError.contentConflict(capture.id.uuidString) }
            let input = try FileHandle(forReadingFrom: original)
            defer { try? input.close() }
            var index = 0
            while let bytes = try input.read(upToCount: chunkBytes), !bytes.isEmpty {
                let staging = folder.appending(path: "restore-\(UUID().uuidString).part")
                try write(bytes, to: staging)
                do {
                    let record = DictationLibrarySchema.record(type: DictationLibrarySchema.chunkRecordType, name: DictationLibrarySchema.chunkName(capture.id, index: index), payload: Data(), hash: LibraryFiles.hash(bytes))
                    record[DictationLibrarySchema.originalAssetKey] = CKAsset(fileURL: staging)
                    try await restoreRecord(record, account: account)
                    try remove(staging)
                } catch {
                    try? remove(staging)
                    throw error
                }
                index += 1
            }
            originalCount += 1
        }
        return DictationRestorationReport(captureCount: captureCount, resultCount: resultCount, originalCount: originalCount, missingOriginalCaptureIDs: missing)
    }

    private func restoreRecord(_ record: CKRecord, account: String) async throws {
        guard try await verifiedAccount() == account else { throw DictationLibraryError.accountChanged }
        try await cloud.create(record)
        guard try await verifiedAccount() == account else { throw DictationLibraryError.accountChanged }
    }

    public func original(for id: UUID) async throws -> URL {
        let account = try await verifiedAccount()
        let key = "\(account)/\(id.uuidString)"
        if let task = downloads[key] { return try await task.value }
        let task = Task { try await downloadOriginal(id, account: account) }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }

    private func downloadOriginal(_ id: UUID, account: String) async throws -> URL {
        let partition = files.partition(account)
        let folder = captureFolder(id, in: partition)
        guard FileManager.default.fileExists(atPath: folder.appending(path: "capture.json").path) else { throw DictationLibraryError.invalidCapture(id) }
        let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        let destination = folder.appending(path: "original.caf")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let byteCount = capture.originalByteCount, let sha = capture.originalSHA256 else { throw DictationLibraryError.noAudio }
        let staging = folder.appending(path: "original.caf.partial")
        try remove(staging)
        try capacity.reserve(byteCount)
        var retained = false
        defer { if !retained { capacity.release(byteCount) } }
        FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: staging)
        defer { try? output.close() }
        var hash = SHA256()
        var receivedBytes: Int64 = 0
        let chunkCount = Int((byteCount + Int64(chunkBytes) - 1) / Int64(chunkBytes))
        do {
            for index in 0..<chunkCount {
                let bytes = try await cloud.originalChunk(CKRecord.ID(recordName: DictationLibrarySchema.chunkName(id, index: index), zoneID: DictationLibrarySchema.zone))
                guard try await cloud.accountIdentifier() == account else { throw DictationLibraryError.accountChanged }
                let expectedBytes = min(Int64(chunkBytes), byteCount - receivedBytes)
                guard Int64(bytes.count) == expectedBytes else { throw DictationLibraryError.contentConflict(id.uuidString) }
                hash.update(data: bytes)
                try output.write(contentsOf: bytes)
                receivedBytes += Int64(bytes.count)
            }
            try output.synchronize()
            guard receivedBytes == byteCount, LibraryFiles.hex(hash.finalize()) == sha else { throw DictationLibraryError.contentConflict(id.uuidString) }
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
            try RecordingFileSystem.syncDirectory(folder)
        } catch {
            try? RecordingFileSystem.remove(staging)
            throw error
        }
        retained = true
        return destination
    }

    @discardableResult public func retainAllOriginals() async throws -> DictationReplicationReport {
        var fetched = 0
        var present = 0
        var failures: [UUID: String] = [:]
        var exceeded = false
        for entry in try await entries() {
            if entry.originalURL != nil { present += 1; continue }
            do {
                _ = try await original(for: entry.id)
                fetched += 1
            } catch DictationLibraryError.capacityExceeded {
                exceeded = true
                failures[entry.id] = "capacity"
                break
            } catch DictationLibraryError.accountChanged {
                throw DictationLibraryError.accountChanged
            } catch {
                failures[entry.id] = String(describing: error)
            }
        }
        return DictationReplicationReport(fetchedCount: fetched, presentCount: present, failures: failures, capacityExceeded: exceeded)
    }

    public func export(to exportsRoot: URL) async throws -> DictationExport {
        let account = try await verifiedAccount()
        let partition = files.partition(account)
        let state = try loadState(partition)
        let accountDirectory = exportsRoot.appending(path: LibraryFiles.hash(Data(account.utf8)), directoryHint: .isDirectory)
        try RecordingFileSystem.createProtectedDirectory(accountDirectory)
        for stale in try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil) where stale.lastPathComponent.hasPrefix(".staging-") {
            try RecordingFileSystem.remove(stale)
        }
        let staging = accountDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try RecordingFileSystem.createProtectedDirectory(staging)
        let manifest: DictationExportManifest
        do {
            manifest = try stage(into: staging, partition: partition, account: account, state: state)
            try LibraryFiles.write(manifest, to: staging.appending(path: "manifest.json"))
        } catch {
            try? RecordingFileSystem.remove(staging)
            throw error
        }
        let final = accountDirectory.appending(path: "\(Self.timestamp(manifest.createdAt))-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: staging, to: final)
        try RecordingFileSystem.syncDirectory(accountDirectory)
        let sealed = try FileManager.default.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != final.lastPathComponent }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sealed.dropFirst(Self.retainedExportCount - 1) { try RecordingFileSystem.remove(old) }
        return DictationExport(directory: final, manifest: manifest)
    }

    private func stage(into staging: URL, partition: URL, account: String, state: State) throws -> DictationExportManifest {
        var entries: [DictationExportManifest.File] = []
        var missing: [UUID] = []
        var resultCount = 0
        let captures = try captures(in: partition).sorted { $0.id.uuidString < $1.id.uuidString }
        for capture in captures {
            let source = captureFolder(capture.id, in: partition)
            let target = staging.appending(path: "captures/\(capture.id.uuidString)", directoryHint: .isDirectory)
            try RecordingFileSystem.createProtectedDirectory(target.appending(path: "results"))
            try link(source.appending(path: "capture.json"), into: target.appending(path: "capture.json"), root: staging, files: &entries)
            for directory in ["results", "outbox"] {
                for result in try LibraryFiles.results(inDirectory: source.appending(path: directory)) {
                    let name = "results/\(result.id.uuidString).json"
                    try link(source.appending(path: "\(directory)/\(result.id.uuidString).json"), into: target.appending(path: name), root: staging, files: &entries)
                    resultCount += 1
                }
            }
            let original = source.appending(path: "original.caf")
            if FileManager.default.fileExists(atPath: original.path), let sha = capture.originalSHA256 {
                try link(original, into: target.appending(path: "original.caf"), root: staging, files: &entries, sha256: sha)
            } else {
                missing.append(capture.id)
            }
        }
        let complete = state.reachedEnd && state.problems.isEmpty && missing.isEmpty
        return DictationExportManifest(
            formatVersion: Self.manifestFormatVersion,
            account: .init(hash: LibraryFiles.hash(Data(account.utf8))),
            createdAt: .now,
            complete: complete,
            freshness: .init(lastCatchUpAt: state.lastCatchUpAt, catchUpReachedEnd: state.reachedEnd),
            completeness: .init(captureCount: captures.count, resultCount: resultCount, audioPresentCount: captures.count - missing.count, missingAudioCaptureIDs: missing, problems: state.problems),
            files: entries.sorted { $0.path < $1.path }
        )
    }

    private func link(_ source: URL, into destination: URL, root: URL, files entries: inout [DictationExportManifest.File], sha256: String? = nil) throws {
        do { try FileManager.default.linkItem(at: source, to: destination) }
        catch { try FileManager.default.copyItem(at: source, to: destination) }
        let size = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let path = String(destination.path.dropFirst(root.path.count + 1))
        let digest = try LibraryFiles.hashFile(destination)
        if let sha256, digest != sha256 { throw DictationLibraryError.contentConflict(path) }
        entries.append(.init(path: path, byteCount: size, sha256: digest))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let fraction = Int64(date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
        return formatter.string(from: date) + String(format: "-%09lld", fraction)
    }

    private enum Applied { case newCapture, newResult, unchanged, ignored }

    private func apply(_ record: CKRecord, in partition: URL) throws -> Applied {
        let name = record.recordID.recordName
        let payload: Data
        let destination: URL
        let isCapture: Bool
        switch record.recordType {
        case DictationLibrarySchema.captureRecordType:
            let capture = try payloadOf(record, as: DictationCapture.self)
            guard name == DictationLibrarySchema.captureName(capture.value.id) else { throw DictationLibraryError.invalidRecord(name) }
            payload = capture.data
            destination = captureFolder(capture.value.id, in: partition).appending(path: "capture.json")
            isCapture = true
        case DictationLibrarySchema.resultRecordType:
            let result = try payloadOf(record, as: DictationResultVersion.self)
            guard name == DictationLibrarySchema.resultName(result.value.id) else { throw DictationLibraryError.invalidRecord(name) }
            payload = result.data
            destination = captureFolder(result.value.captureID, in: partition).appending(path: "results/\(result.value.id.uuidString).json")
            isCapture = false
        default:
            return .ignored
        }
        if !isCapture {
            let pending = destination.deletingLastPathComponent().deletingLastPathComponent().appending(path: "outbox/\(destination.lastPathComponent)")
            if FileManager.default.fileExists(atPath: pending.path) {
                guard try Data(contentsOf: pending) == payload else { throw DictationLibraryError.contentConflict(name) }
                try remove(pending)
            }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == payload else { throw DictationLibraryError.contentConflict(name) }
            return .unchanged
        }
        try RecordingFileSystem.createProtectedDirectory(destination.deletingLastPathComponent())
        try write(payload, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
        return isCapture ? .newCapture : .newResult
    }

    private func payloadOf<T: Decodable>(_ record: CKRecord, as type: T.Type) throws -> (value: T, data: Data) {
        guard let data = record.encryptedValues["payload"] as? Data else { throw DictationLibraryError.invalidRecord(record.recordID.recordName) }
        return (try DictationLibrarySchema.value(type, from: record), data)
    }

    private func captures(in partition: URL) throws -> [DictationCapture] {
        let directory = partition.appending(path: "captures")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && FileManager.default.fileExists(atPath: $0.appending(path: "capture.json").path) }
            .map { try LibraryFiles.read(DictationCapture.self, at: $0.appending(path: "capture.json")) }
    }

    private func results(in folder: URL) throws -> [DictationResultVersion] {
        try (LibraryFiles.results(inDirectory: folder.appending(path: "results")) + LibraryFiles.results(inDirectory: folder.appending(path: "outbox")))
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    private func captureFolder(_ id: UUID, in partition: URL) -> URL {
        partition.appending(path: "captures/\(id.uuidString)", directoryHint: .isDirectory)
    }

    private func loadState(_ partition: URL) throws -> State {
        let url = partition.appending(path: "state.json")
        return FileManager.default.fileExists(atPath: url.path) ? try LibraryFiles.read(State.self, at: url) : State()
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try capacity.write(value, to: url)
    }

    private func write(_ bytes: Data, to url: URL) throws {
        try capacity.write(bytes, to: url)
    }

    private func remove(_ url: URL) throws {
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        try RecordingFileSystem.remove(url)
        capacity.release(bytes)
    }

    private func verifiedAccount() async throws -> String {
        guard let account = try await cloud.accountIdentifier() else { throw DictationLibraryError.accountUnavailable }
        return account
    }
}
