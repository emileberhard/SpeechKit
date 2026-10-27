import AVFAudio
import CloudKit
import Foundation
import SpeechKit

public struct DictationAccountSession: Codable, Equatable, Sendable {
    public let accountIdentifier: String
    public let epoch: UUID
}

public enum DictationProfileState: Equatable, Sendable {
    case unverified
    case unavailable
    case absent
    case ready(DictationProfileSnapshot)
}

private final class AccountObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(_ handler: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in handler() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

public struct DictationCaptureFailure: Equatable, Sendable {
    public let captureID: UUID
    public let message: String
}

public struct DictationPublicationStatus: Equatable, Sendable {
    public let pendingCaptureCount: Int
    public let heldCaptureCount: Int
    public let unverifiedCaptureCount: Int
    public let usedBytes: Int64
    public let capacityBytes: Int64
    public let releasableBytes: Int64
    public let failures: [DictationCaptureFailure]
}

public actor DictationLibraryStore {
    private struct WeakWriter { weak var value: DictationCaptureWriter? }
    private let files: LibraryFiles
    private let source: String
    private let cloud: any LibraryCloud
    private let chunkBytes: Int
    private let capacity: LibraryCapacity
    private static let captureHeadroomBytes: Int64 = 16_384
    private var epoch = UUID()
    private var session: DictationAccountSession?
    private var profile: DictationProfileState = .unverified
    private var profileRevision = UUID()
    private var accountObserver: AccountObservation?
    private var observers: [UUID: AsyncStream<DictationAccountSession?>.Continuation] = [:]
    private var writers: [UUID: WeakWriter] = [:]
    private var publishing = false
    private var publishAgain = false
    private var captureFailures: [String: String] = [:]
    private var recoveryFolders: Set<URL>?

    public init(directory: URL, source: String, capacityBytes: Int64, containerIdentifier: String) throws {
        try self.init(directory: directory, source: source, capacityBytes: capacityBytes, cloud: CloudKitLibraryCloud(containerIdentifier: containerIdentifier))
    }

    init(directory: URL, source: String, capacityBytes: Int64, cloud: any LibraryCloud, chunkBytes: Int = DictationLibrarySchema.chunkBytes) throws {
        guard capacityBytes > 0, !source.isEmpty else { throw DictationLibraryError.invalidConfiguration }
        files = LibraryFiles(root: directory)
        self.source = source
        self.cloud = cloud
        self.chunkBytes = chunkBytes
        try RecordingFileSystem.createProtectedDirectory(directory)
        capacity = LibraryCapacity(limit: capacityBytes, used: try files.usedBytes())
    }

    public func accountSession() -> DictationAccountSession? { session }
    public func profileState() -> DictationProfileState { profile }

    public func accountEvents() -> AsyncStream<DictationAccountSession?> {
        observeAccount()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(session)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func observeAccount() {
        guard accountObserver == nil else { return }
        accountObserver = AccountObservation { [weak self] in
            Task { await self?.accountNotification() }
        }
    }

    private func accountNotification() async {
        accountDidChange()
        do { _ = try await refresh() } catch { }
    }

    public func accountDidChange() {
        epoch = UUID()
        session = nil
        profile = .unverified
        for observer in observers.values { observer.yield(nil) }
    }

    @discardableResult public func refresh() async throws -> DictationProfileSnapshot? {
        observeAccount()
        let generation = epoch
        do {
            guard let account = try await cloud.accountIdentifier() else {
                guard generation == epoch else { throw DictationLibraryError.accountChanged }
                accountDidChange()
                profile = .unavailable
                throw DictationLibraryError.accountUnavailable
            }
            guard generation == epoch else { throw DictationLibraryError.accountChanged }
            if let session, session.accountIdentifier != account {
                accountDidChange()
                throw DictationLibraryError.accountChanged
            }
            session = DictationAccountSession(accountIdentifier: account, epoch: epoch)
            for observer in observers.values { observer.yield(session) }
            let cachedURL = files.partition(account).appending(path: "profile.json")
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                let cached = try LibraryFiles.read(DictationProfileSnapshot.self, at: cachedURL)
                guard cached.accountIdentifier == account else { throw DictationLibraryError.accountChanged }
                profile = .ready(cached)
            }
            let value: DictationProfile?
            let revision = profileRevision
            do { value = try await cloud.profile() }
            catch {
                guard generation == epoch, session?.accountIdentifier == account else { throw DictationLibraryError.accountChanged }
                if case .ready(let cached) = profile { return cached }
                throw Self.libraryError(error)
            }
            guard try await cloud.accountIdentifier() == account, generation == epoch else {
                accountDidChange()
                throw DictationLibraryError.accountChanged
            }
            if revision != profileRevision {
                if case .ready(let snapshot) = profile { return snapshot }
                if case .absent = profile { return nil }
                throw DictationLibraryError.profileUnavailable
            }
            guard let value else { profile = .absent; return nil }
            let snapshot = DictationProfileSnapshot(accountIdentifier: account, refreshedAt: .now, profile: value)
            try capacity.write(snapshot, to: cachedURL)
            profile = .ready(snapshot)
            return snapshot
        } catch {
            if generation == epoch, case .ready = profile {} else if generation == epoch { profile = .unavailable }
            throw Self.libraryError(error)
        }
    }

    private static func libraryError(_ error: any Error) -> any Error {
        if error is DictationLibraryError || error is CancellationError { return error }
        let error = error as NSError
        return DictationLibraryError.cloudFailure("\(error.domain) \(error.code)")
    }

    public func saveProfile(_ value: DictationProfile, session lease: DictationAccountSession) async throws {
        try validate(lease)
        let current = try await verifiedSession()
        guard current == lease else { throw DictationLibraryError.accountChanged }
        try await cloud.saveProfile(value)
        try validate(lease)
        profileRevision = UUID()
        _ = try await refresh()
    }

    public func updateDictionarySnapshot(_ terms: [String], session lease: DictationAccountSession) throws {
        try validate(lease)
        guard case .ready(let snapshot) = profile else { throw DictationLibraryError.profileUnavailable }
        var value = snapshot.profile
        value.dictionary = terms
        let updated = DictationProfileSnapshot(accountIdentifier: lease.accountIdentifier, refreshedAt: snapshot.refreshedAt, profile: value)
        try capacity.write(updated, to: files.partition(lease.accountIdentifier).appending(path: "profile.json"))
        profile = .ready(updated)
    }

    public func restoreCachedProfile(session lease: DictationAccountSession) async throws -> Bool {
        try validate(lease)
        let url = files.partition(lease.accountIdentifier).appending(path: "profile.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let snapshot = try LibraryFiles.read(DictationProfileSnapshot.self, at: url)
        guard snapshot.accountIdentifier == lease.accountIdentifier else { throw DictationLibraryError.accountChanged }
        try await saveProfile(snapshot.profile, session: lease)
        return true
    }

    public func makePlan(context: DictationContext, capabilities: DictationCapabilities) throws -> DictationPlan {
        let (profile, session) = try verifiedProfile()
        return DictationPlan(profile: profile, context: context, capabilities: capabilities, accountSession: session)
    }

    public func makePlan(context: DictationContext, capabilities: DictationCapabilities, dictionary: [String]) throws -> DictationPlan {
        var (profile, session) = try verifiedProfile()
        profile.dictionary = dictionary
        return DictationPlan(profile: profile, context: context, capabilities: capabilities, accountSession: session)
    }

    private func verifiedProfile() throws -> (DictationProfile, DictationAccountSession) {
        guard let session else { throw DictationLibraryError.accountUnavailable }
        switch profile {
        case .absent: throw DictationLibraryError.notConfigured
        case .unverified, .unavailable: throw DictationLibraryError.profileUnavailable
        case .ready: break
        }
        guard case .ready(let snapshot) = profile, snapshot.accountIdentifier == session.accountIdentifier else { throw DictationLibraryError.profileUnavailable }
        return (snapshot.profile, session)
    }

    public func validateAccountSession(_ lease: DictationAccountSession) throws { try validate(lease) }

    public func beginCapture(plan: DictationPlan) throws -> DictationCaptureWriter {
        guard plan.archiveEnabled else { throw DictationLibraryError.archiveDisabled }
        if let lease = plan.accountSession { try validate(lease) }
        try capacity.requireHeadroom(Self.captureHeadroomBytes)
        let capture = DictationCapture(formatVersion: 1, id: UUID(), account: plan.accountSession.map { DictationAccountStamp(accountIdentifier: $0.accountIdentifier, epoch: $0.epoch) }, source: source, startedAt: .now, sampleRate: nil, plan: plan, finishedAt: nil, interrupted: false, originalSHA256: nil, originalByteCount: nil)
        let writer = try DictationCaptureWriter(capture: capture, folder: files.folder(capture.id, account: capture.account?.accountIdentifier), capacity: capacity)
        writers[capture.id] = WeakWriter(value: writer)
        recoveryFolders?.insert(files.folder(capture.id, account: capture.account?.accountIdentifier))
        if publishing { publishAgain = true }
        return writer
    }

    public func addResult(_ result: DictationResultVersion) throws {
        let folder = try captureFolder(result.captureID)
        let destination = folder.appending(path: "results/\(result.id.uuidString).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try LibraryFiles.read(DictationResultVersion.self, at: destination) == result else { throw DictationLibraryError.contentConflict(result.id.uuidString) }
            return
        }
        try capacity.write(result, to: destination)
        if publishing { publishAgain = true }
    }

    public func capture(id: UUID) throws -> DictationCapture? {
        guard let folder = try findCaptureFolder(id) else { return nil }
        let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        guard let account = capture.account?.accountIdentifier, let session else { throw DictationLibraryError.accountUnavailable }
        guard account == session.accountIdentifier else { throw DictationLibraryError.accountChanged }
        return capture
    }

    public func validateCapture(id: UUID) throws {
        guard try capture(id: id) != nil else { throw DictationLibraryError.invalidCapture(id) }
    }

    public func ownership(ofCapture id: UUID) throws -> DictationCaptureOwnership {
        guard let folder = try findCaptureFolder(id) else { return .unknown }
        let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        guard let account = capture.account?.accountIdentifier else { return .held }
        return account == session?.accountIdentifier ? .current : .otherAccount
    }

    public func heldCaptures() throws -> [DictationHeldCapture] {
        try allCaptures().compactMap { capture in
            let reason: DictationHeldReason
            if capture.account == nil { reason = .unverifiedPlan }
            else if capture.account?.accountIdentifier != session?.accountIdentifier { reason = .otherAccount }
            else { return nil }
            let original = try files.folder(capture.id, account: capture.account?.accountIdentifier).appending(path: "original.caf")
            return DictationHeldCapture(capture: capture, reason: reason, originalURL: FileManager.default.fileExists(atPath: original.path) ? original : nil)
        }.sorted { $0.capture.startedAt > $1.capture.startedAt }
    }

    public func reconcileHeldCapture(id: UUID, session lease: DictationAccountSession) throws {
        try validate(lease)
        let folder = try captureFolder(id)
        var capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        guard capture.account == nil else { throw DictationLibraryError.heldCapture(id) }
        guard writers[id]?.value?.isFinished != false else { throw DictationLibraryError.recordingFinished }
        let destination = files.folder(id, account: lease.accountIdentifier)
        if folder.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path {
            capture.account = DictationAccountStamp(accountIdentifier: lease.accountIdentifier, epoch: lease.epoch)
            try capacity.write(capture, to: destination.appending(path: "capture.json"))
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DictationLibraryError.contentConflict(id.uuidString) }
        try RecordingFileSystem.createProtectedDirectory(destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: folder, to: destination)
        if recoveryFolders?.remove(folder) != nil { recoveryFolders?.insert(destination) }
        try RecordingFileSystem.syncDirectory(destination.deletingLastPathComponent())
        capture.account = DictationAccountStamp(accountIdentifier: lease.accountIdentifier, epoch: lease.epoch)
        try capacity.write(capture, to: destination.appending(path: "capture.json"))
    }

    public func recoverInterruptedCaptures() throws -> [DictationCapture] {
        var recovered: [DictationCapture] = []
        if recoveryFolders == nil {
            recoveryFolders = Set(try captureFolders())
        }
        for folder in recoveryFolders ?? [] {
            do {
                var capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
                guard writers[capture.id]?.value?.isFinished != false else { continue }
                if capture.originalSHA256 != nil {
                    let journal = folder.appending(path: "journal")
                    try capacity.remove(journal)
                    captureFailures[folder.resolvingSymlinksInPath().path] = nil
                    recoveryFolders?.remove(folder)
                    continue
                }
                let pcm = folder.appending(path: "journal/\(capture.id.uuidString)/audio.pcm")
                let original = folder.appending(path: "original.caf")
                let originalExists = FileManager.default.fileExists(atPath: original.path)
                let hasAudio = ((try? pcm.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 2
                guard originalExists || hasAudio else {
                    if !hasAudio, try LibraryFiles.results(in: folder).isEmpty { try capacity.remove(folder) }
                    recoveryFolders?.remove(folder)
                    captureFailures[folder.resolvingSymlinksInPath().path] = nil
                    continue
                }
                if !originalExists {
                    guard let rate = capture.sampleRate else { throw DictationLibraryError.invalidConfiguration }
                    try OpusOriginal.seal(pcm: pcm, sampleRate: rate, destination: original, capacity: capacity)
                }
                capture.interrupted = true
                capture.finishedAt = .now
                capture.originalSHA256 = try LibraryFiles.hashFile(original)
                capture.originalByteCount = Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                try capacity.write(capture, to: folder.appending(path: "capture.json"))
                try capacity.remove(folder.appending(path: "journal"))
                recovered.append(capture)
                recoveryFolders?.remove(folder)
                captureFailures[folder.resolvingSymlinksInPath().path] = nil
            } catch {
                captureFailures[folder.resolvingSymlinksInPath().path] = error.localizedDescription
            }
        }
        return recovered
    }

    private func captureFolders() throws -> [URL] {
        let partitions = try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return try partitions.flatMap { partition in
            try FileManager.default.contentsOfDirectory(at: partition, includingPropertiesForKeys: nil)
                .filter { UUID(uuidString: $0.lastPathComponent) != nil }
        }
    }

    private func allCaptures() throws -> [DictationCapture] {
        try captureFolders().compactMap { folder in
            do { return try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json")) }
            catch { captureFailures[folder.resolvingSymlinksInPath().path] = error.localizedDescription; return nil }
        }
    }

    private func captures(in partition: URL) throws -> [DictationCapture] {
        guard FileManager.default.fileExists(atPath: partition.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: partition, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder in
                do { return try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json")) }
                catch { captureFailures[folder.resolvingSymlinksInPath().path] = error.localizedDescription; return nil }
            }
    }

    private func captures(account: String) throws -> [DictationCapture] {
        try captures(in: files.partition(account))
    }

    public func entries() throws -> [DictationArchiveEntry] {
        guard let account = session?.accountIdentifier else { return [] }
        return try captures(account: account).compactMap { capture in
            let folder = files.folder(capture.id, account: account)
            let original = folder.appending(path: "original.caf")
            do {
                return try DictationArchiveEntry(capture: capture, results: LibraryFiles.results(in: folder), originalURL: FileManager.default.fileExists(atPath: original.path) ? original : nil, published: isPublished(capture, folder: folder))
            } catch { captureFailures[folder.resolvingSymlinksInPath().path] = error.localizedDescription; return nil }
        }.sorted { $0.capture.startedAt > $1.capture.startedAt }
    }

    private struct PublicationCapture {
        let capture: DictationCapture
        let folder: URL
        var acknowledged: Set<String>
        let results: [URL]
    }

    private func publicationInventory() throws -> [PublicationCapture] {
        try captureFolders().compactMap { folder in
            do {
                let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
                guard capture.account?.accountIdentifier == session?.accountIdentifier, capture.account != nil else {
                    return PublicationCapture(capture: capture, folder: folder, acknowledged: [], results: [])
                }
                guard folder.standardizedFileURL == files.folder(capture.id, account: capture.account?.accountIdentifier).standardizedFileURL else { throw DictationLibraryError.invalidCapture(capture.id) }
                return try PublicationCapture(capture: capture, folder: folder, acknowledged: acknowledgements(folder), results: LibraryFiles.resultFiles(in: folder))
            } catch { captureFailures[folder.resolvingSymlinksInPath().path] = error.localizedDescription; return nil }
        }
    }

    private func chunkNames(_ capture: DictationCapture) -> [String] {
        guard let count = capture.originalByteCount, count > 0 else { return [] }
        return (0..<Int((count - 1) / Int64(chunkBytes) + 1)).map { DictationLibrarySchema.chunkName(capture.id, index: $0) }
    }

    private func isPublished(_ item: PublicationCapture) -> Bool {
        guard item.capture.originalSHA256 != nil, let count = item.capture.originalByteCount, count > 0 else { return false }
        let expected = [DictationLibrarySchema.captureName(item.capture.id)] + chunkNames(item.capture)
            + item.results.map { DictationLibrarySchema.resultName(UUID(uuidString: $0.deletingPathExtension().lastPathComponent)!) }
        return Set(expected).isSubset(of: item.acknowledged)
    }

    public func status() throws -> DictationPublicationStatus {
        try status(inventory: publicationInventory())
    }

    private func status(inventory: [PublicationCapture]) throws -> DictationPublicationStatus {
        var pending = 0
        var held = 0
        var unverified = 0
        var releasable: Int64 = 0
        for item in inventory {
            if item.capture.account == nil { held += 1; unverified += 1 }
            else if item.capture.account?.accountIdentifier != session?.accountIdentifier { held += 1 }
            else if !isPublished(item) { pending += 1 }
            else if FileManager.default.fileExists(atPath: item.folder.appending(path: "original.caf").path) {
                releasable += item.capture.originalByteCount ?? 0
            }
        }
        let partitions = [files.partition(session?.accountIdentifier).resolvingSymlinksInPath().path, files.partition(nil).resolvingSymlinksInPath().path]
        let failures = captureFailures.compactMap { path, message -> DictationCaptureFailure? in
            let folder = URL(fileURLWithPath: path)
            guard partitions.contains(folder.deletingLastPathComponent().resolvingSymlinksInPath().path), let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            return DictationCaptureFailure(captureID: id, message: message)
        }.sorted { $0.captureID.uuidString < $1.captureID.uuidString }
        return DictationPublicationStatus(pendingCaptureCount: pending, heldCaptureCount: held, unverifiedCaptureCount: unverified, usedBytes: capacity.usedBytes, capacityBytes: capacity.limit, releasableBytes: releasable, failures: failures)
    }

    public func releasePublishedOriginals(finishedBefore cutoff: Date, session: DictationAccountSession) throws -> DictationReleaseReport {
        try validate(session)
        var count = 0
        var bytes: Int64 = 0
        var retained = 0
        for capture in try captures(account: session.accountIdentifier) {
            let folder = files.folder(capture.id, account: session.accountIdentifier)
            let original = folder.appending(path: "original.caf")
            guard FileManager.default.fileExists(atPath: original.path) else { continue }
            guard isPublished(capture, folder: folder), let finishedAt = capture.finishedAt, finishedAt < cutoff else { retained += 1; continue }
            try capacity.write(ReleaseMarker(releasedAt: .now), to: folder.appending(path: Self.releaseMarker))
            let size = Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            try RecordingFileSystem.remove(original)
            capacity.release(size)
            count += 1
            bytes += size
        }
        return DictationReleaseReport(releasedCount: count, releasedBytes: bytes, retainedUnpublishedCount: retained)
    }

    @discardableResult public func reseedPublication(session: DictationAccountSession) throws -> Int {
        try validate(session)
        var reset = 0
        for capture in try captures(account: session.accountIdentifier) {
            let folder = files.folder(capture.id, account: session.accountIdentifier)
            guard FileManager.default.fileExists(atPath: folder.appending(path: Self.acknowledgementFile).path) else { continue }
            try capacity.remove(folder.appending(path: Self.acknowledgementFile))
            reset += 1
        }
        return reset
    }

    @discardableResult public func publishPending() async throws -> DictationPublicationStatus {
        guard !publishing else { publishAgain = true; return try status() }
        publishing = true
        defer { publishing = false }
        var inventory: [PublicationCapture]
        repeat {
            publishAgain = false
            let lease = try await verifiedSession()
            inventory = try publicationInventory()
            for index in inventory.indices {
                try validate(lease)
                let item = inventory[index]
                guard item.capture.account?.accountIdentifier == lease.accountIdentifier, item.capture.originalSHA256 != nil else { continue }
                do {
                    inventory[index].acknowledged = try await publishCapture(item, lease: lease)
                    captureFailures[item.folder.resolvingSymlinksInPath().path] = nil
                } catch DictationLibraryError.accountChanged { throw DictationLibraryError.accountChanged }
                catch is CancellationError { throw CancellationError() }
                catch { captureFailures[item.folder.resolvingSymlinksInPath().path] = error.localizedDescription }
            }
            try validate(lease)
        } while publishAgain
        return try status(inventory: inventory)
    }

    private func publishCapture(_ item: PublicationCapture, lease: DictationAccountSession) async throws -> Set<String> {
        let capture = item.capture
        guard let byteCount = capture.originalByteCount, byteCount > 0 else { throw DictationLibraryError.invalidCapture(capture.id) }
        let folder = item.folder
        var acknowledged = item.acknowledged
        let missingChunks = chunkNames(capture).enumerated().filter { !acknowledged.contains($0.element) }
        let captureName = DictationLibrarySchema.captureName(capture.id)
        let original = folder.appending(path: "original.caf")
        let released = FileManager.default.fileExists(atPath: folder.appending(path: Self.releaseMarker).path)
        if !released, !missingChunks.isEmpty || !acknowledged.contains(captureName) {
            guard Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == byteCount,
                  try LibraryFiles.hashFile(original) == capture.originalSHA256 else { throw DictationLibraryError.contentConflict(capture.id.uuidString) }
        }
        if !acknowledged.contains(captureName) {
            let payload = try LibraryFiles.encode(capture.publishedForm)
            try await publish(DictationLibrarySchema.record(type: DictationLibrarySchema.captureRecordType, name: captureName, payload: payload, hash: LibraryFiles.hash(payload)), lease: lease, folder: folder, acknowledged: &acknowledged)
        }
        if !released, !missingChunks.isEmpty {
            let input = try FileHandle(forReadingFrom: original)
            defer { try? input.close() }
            for (index, name) in missingChunks {
                try input.seek(toOffset: UInt64(index) * UInt64(chunkBytes))
                let expected = Int(min(Int64(chunkBytes), byteCount - Int64(index) * Int64(chunkBytes)))
                guard let bytes = try input.read(upToCount: expected), bytes.count == expected else { throw DictationLibraryError.contentConflict(capture.id.uuidString) }
                let staging = folder.appending(path: "upload-\(index).part")
                try bytes.write(to: staging, options: .atomic)
                defer { try? FileManager.default.removeItem(at: staging) }
                let record = DictationLibrarySchema.record(type: DictationLibrarySchema.chunkRecordType, name: name, payload: Data(), hash: LibraryFiles.hash(bytes))
                record[DictationLibrarySchema.originalAssetKey] = CKAsset(fileURL: staging)
                try await publish(record, lease: lease, folder: folder, acknowledged: &acknowledged)
            }
        }
        for url in item.results {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)!
            let name = DictationLibrarySchema.resultName(id)
            guard !acknowledged.contains(name) else { continue }
            let result = try LibraryFiles.read(DictationResultVersion.self, at: url)
            guard result.id == id, result.captureID == capture.id else { throw DictationLibraryError.invalidRecord(name) }
            let data = try LibraryFiles.encode(result)
            try await publish(DictationLibrarySchema.record(type: DictationLibrarySchema.resultRecordType, name: name, payload: data, hash: LibraryFiles.hash(data)), lease: lease, folder: folder, acknowledged: &acknowledged)
        }
        return acknowledged
    }

    private func publish(_ record: CKRecord, lease: DictationAccountSession, folder: URL, acknowledged: inout Set<String>) async throws {
        guard !acknowledged.contains(record.recordID.recordName) else { return }
        try validate(lease)
        guard try await cloud.accountIdentifier() == lease.accountIdentifier else { accountDidChange(); throw DictationLibraryError.accountChanged }
        try validate(lease)
        do { try await cloud.create(record) } catch { throw Self.libraryError(error) }
        try validate(lease)
        acknowledged.insert(record.recordID.recordName)
        try capacity.write(acknowledged.sorted(), to: folder.appending(path: Self.acknowledgementFile))
    }

    private func verifiedSession() async throws -> DictationAccountSession {
        guard let lease = session else { throw DictationLibraryError.accountUnavailable }
        guard try await cloud.accountIdentifier() == lease.accountIdentifier else { accountDidChange(); throw DictationLibraryError.accountChanged }
        try validate(lease)
        return lease
    }

    private func validate(_ lease: DictationAccountSession) throws {
        try Task.checkCancellation()
        guard session == lease, epoch == lease.epoch else { throw DictationLibraryError.accountChanged }
    }

    private func findCaptureFolder(_ id: UUID) throws -> URL? {
        guard FileManager.default.fileExists(atPath: files.root.path) else { return nil }
        let partitions = try FileManager.default.contentsOfDirectory(at: files.root, includingPropertiesForKeys: [.isDirectoryKey])
        let matches = partitions.map { $0.appending(path: id.uuidString) }.filter { FileManager.default.fileExists(atPath: $0.appending(path: "capture.json").path) }
        guard matches.count <= 1 else { throw DictationLibraryError.contentConflict(id.uuidString) }
        return matches.first
    }

    private func captureFolder(_ id: UUID) throws -> URL {
        guard let folder = try findCaptureFolder(id) else { throw DictationLibraryError.invalidCapture(id) }
        return folder
    }

    private func acknowledgements(_ folder: URL) throws -> Set<String> {
        let url = folder.appending(path: Self.acknowledgementFile)
        return FileManager.default.fileExists(atPath: url.path) ? Set(try LibraryFiles.read([String].self, at: url)) : []
    }

    private func isPublished(_ capture: DictationCapture, folder: URL) -> Bool {
        guard let acknowledged = try? acknowledgements(folder), let results = try? LibraryFiles.resultFiles(in: folder) else { return false }
        return isPublished(PublicationCapture(capture: capture, folder: folder, acknowledged: acknowledged, results: results))
    }

    private struct ReleaseMarker: Codable { let releasedAt: Date }
    private static let releaseMarker = "released.json"
    private static let acknowledgementFile = "published.json"
}
