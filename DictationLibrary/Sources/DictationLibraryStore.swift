import AVFAudio
import CloudKit
import Foundation
import SpeechKit
import Synchronization

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

private struct AccountChanged: NotificationCenter.AsyncMessage {
    typealias Subject = CKContainer
    static var name: Notification.Name { .CKAccountChanged }
    static func makeMessage(_ notification: Notification) -> Self? { Self() }
}

public struct DictationCaptureFailure: Equatable, Sendable {
    public let captureID: UUID
    public let error: DictationLibraryError
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
    private nonisolated let sessionSnapshot = Mutex<DictationAccountSession?>(nil)
    private var session: DictationAccountSession? {
        get { sessionSnapshot.withLock { $0 } }
        set { sessionSnapshot.withLock { $0 = newValue } }
    }
    private var profile: DictationProfileState = .unverified
    private var profileRevision = UUID()
    private var accountObserver: NotificationCenter.ObservationToken?
    private var observers: [UUID: AsyncStream<DictationAccountSession?>.Continuation] = [:]
    private var writers: [UUID: WeakWriter] = [:]
    private var publishing = false
    private var publishAgain = false
    private var receiptsReset = false
    private var readFailures: [String: DictationLibraryError] = [:]
    private var recoveryFailures: [String: DictationLibraryError] = [:]
    private var publishFailures: [String: DictationLibraryError] = [:]
    private var entryFailures: [String: DictationLibraryError] = [:]
    private var reclaimFailures: [String: DictationLibraryError] = [:]
    private var index: [String: CaptureSummary]?
    private var indexLoad: Task<LoadedIndex, any Error>?
    private var staleCaptures: Set<UUID> = []

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

    public nonisolated func accountSession() -> DictationAccountSession? { sessionSnapshot.withLock { $0 } }
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
        accountObserver = NotificationCenter.default.addObserver(of: nil, for: AccountChanged.self) { [weak self] _ in
            await self?.accountNotification()
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
            try capacity.writeBeyondLimit(snapshot, to: cachedURL)
            profile = .ready(snapshot)
            return snapshot
        } catch {
            if generation == epoch, case .ready = profile {} else if generation == epoch { profile = .unavailable }
            throw Self.libraryError(error)
        }
    }

    private static func libraryError(_ error: any Error) -> any Error {
        if error is DictationLibraryError || error is CancellationError { return error }
        if Task.isCancelled, let error = error as? CKError, error.code == .operationCancelled { return CancellationError() }
        return DictationLibraryError(error)
    }

    public func saveProfile(_ value: DictationProfile, session lease: DictationAccountSession) async throws {
        try validateAccountSession(lease)
        let current = try await verifiedSession()
        guard current == lease else { throw DictationLibraryError.accountChanged }
        try await cloud.saveProfile(value)
        try validateAccountSession(lease)
        profileRevision = UUID()
        _ = try await refresh()
    }

    public func updateDictionarySnapshot(_ terms: [String], session lease: DictationAccountSession) throws {
        try validateAccountSession(lease)
        guard case .ready(let snapshot) = profile else { throw DictationLibraryError.profileUnavailable }
        var value = snapshot.profile
        value.dictionary = terms
        let updated = DictationProfileSnapshot(accountIdentifier: lease.accountIdentifier, refreshedAt: snapshot.refreshedAt, profile: value)
        try capacity.writeBeyondLimit(updated, to: files.partition(lease.accountIdentifier).appending(path: "profile.json"))
        profile = .ready(updated)
    }

    public func restoreCachedProfile(session lease: DictationAccountSession) async throws -> Bool {
        try validateAccountSession(lease)
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

    public nonisolated func validateAccountSession(_ lease: DictationAccountSession) throws {
        try Task.checkCancellation()
        guard accountSession() == lease else { throw DictationLibraryError.accountChanged }
    }

    public func beginCapture(plan: DictationPlan) throws -> DictationCaptureWriter {
        guard plan.archiveEnabled else { throw DictationLibraryError.archiveDisabled }
        if let lease = plan.accountSession { try validateAccountSession(lease) }
        try capacity.requireHeadroom(Self.captureHeadroomBytes)
        let capture = DictationCapture(formatVersion: 1, id: UUID(), account: plan.accountSession.map { DictationAccountStamp(accountIdentifier: $0.accountIdentifier, epoch: $0.epoch) }, source: source, startedAt: .now, sampleRate: nil, plan: plan, finishedAt: nil, interrupted: false, originalSHA256: nil, originalByteCount: nil)
        let writer = try DictationCaptureWriter(capture: capture, folder: files.folder(capture.id, account: capture.account?.accountIdentifier), capacity: capacity)
        writers[capture.id] = WeakWriter(value: writer)
        staleCaptures.insert(capture.id)
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
        staleCaptures.insert(result.captureID)
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

    public func heldCaptures() async throws -> [DictationHeldCapture] {
        let captures = try await indexedCaptures()
        let current = session?.accountIdentifier
        let read = await Self.heldEntries(captures.filter { $0.account == nil || $0.account != current }, current: current, files: files)
        guard session?.accountIdentifier == current else { return try await heldCaptures() }
        staleCaptures.formUnion(read.unreadable)
        return read.held
    }

    @concurrent private static func heldEntries(_ captures: [CaptureSummary], current: String?, files: LibraryFiles) async -> (held: [DictationHeldCapture], unreadable: [UUID]) {
        var held: [DictationHeldCapture] = []
        var unreadable: [UUID] = []
        for summary in captures {
            do {
                let capture = try LibraryFiles.read(DictationCapture.self, at: summary.folder.appending(path: "capture.json"))
                let account = capture.account?.accountIdentifier
                guard account == nil || account != current else { continue }
                let original = files.folder(capture.id, account: account).appending(path: "original.caf")
                held.append(DictationHeldCapture(capture: capture, reason: account == nil ? .unverifiedPlan : .otherAccount,
                    originalURL: FileManager.default.fileExists(atPath: original.path) ? original : nil))
            } catch { unreadable.append(summary.id) }
        }
        return (held.sorted { $0.capture.startedAt > $1.capture.startedAt }, unreadable)
    }

    public func reconcileHeldCapture(id: UUID, session lease: DictationAccountSession) throws {
        try validateAccountSession(lease)
        let folder = try captureFolder(id)
        var capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        guard capture.account == nil else { throw DictationLibraryError.heldCapture(id) }
        guard writers[id]?.value?.isFinished != false else { throw DictationLibraryError.recordingFinished }
        staleCaptures.insert(id)
        let destination = files.folder(id, account: lease.accountIdentifier)
        if folder.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path {
            capture.account = DictationAccountStamp(accountIdentifier: lease.accountIdentifier, epoch: lease.epoch)
            try capacity.write(capture, to: destination.appending(path: "capture.json"))
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DictationLibraryError.contentConflict(id.uuidString) }
        try RecordingFileSystem.createProtectedDirectory(destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: folder, to: destination)
        try RecordingFileSystem.syncDirectory(destination.deletingLastPathComponent())
        capture.account = DictationAccountStamp(accountIdentifier: lease.accountIdentifier, epoch: lease.epoch)
        try capacity.write(capture, to: destination.appending(path: "capture.json"))
    }

    public func recoverInterruptedCaptures() async throws -> [DictationCapture] {
        var recovered: [DictationCapture] = []
        let candidates = Set(try await indexedCaptures().filter { !$0.sealed || $0.hasJournal }.map(\.folder.path))
            .union(readFailures.keys).union(recoveryFailures.keys)
        for folder in candidates.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            guard FileManager.default.fileExists(atPath: folder.path) else { recoveryFailures[folder.path] = nil; continue }
            if let id = UUID(uuidString: folder.lastPathComponent) { staleCaptures.insert(id) }
            do {
                var capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
                guard writers[capture.id]?.value?.isFinished != false else { continue }
                if capture.originalSHA256 != nil {
                    let journal = folder.appending(path: "journal")
                    try capacity.remove(journal)
                    recoveryFailures[folder.path] = nil
                    continue
                }
                let pcm = folder.appending(path: "journal/\(capture.id.uuidString)/audio.pcm")
                let original = folder.appending(path: "original.caf")
                let originalExists = FileManager.default.fileExists(atPath: original.path)
                let hasAudio = ((try? pcm.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 2
                guard originalExists || hasAudio else {
                    if try writers[capture.id] == nil || LibraryFiles.results(in: folder).isEmpty { try capacity.remove(folder) }
                    recoveryFailures[folder.path] = nil
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
                recoveryFailures[folder.path] = nil
            } catch {
                recoveryFailures[folder.path] = DictationLibraryError(error)
            }
        }
        return recovered
    }

    public func entries() async throws -> [DictationArchiveEntry] {
        guard let lease = session else { return [] }
        let read = await Self.archiveEntries(try await capturesInPartition(of: lease))
        try validateAccountSession(lease)
        entryFailures = read.failures
        return read.entries
    }

    @concurrent private static func archiveEntries(_ captures: [CaptureSummary]) async -> (entries: [DictationArchiveEntry], failures: [String: DictationLibraryError]) {
        var entries: [DictationArchiveEntry] = []
        var failures: [String: DictationLibraryError] = [:]
        for summary in captures {
            let original = summary.folder.appending(path: "original.caf")
            do {
                let capture = try LibraryFiles.read(DictationCapture.self, at: summary.folder.appending(path: "capture.json"))
                entries.append(DictationArchiveEntry(capture: capture, results: try LibraryFiles.results(in: summary.folder),
                    originalURL: FileManager.default.fileExists(atPath: original.path) ? original : nil, published: summary.published))
            } catch { failures[summary.folder.path] = DictationLibraryError(error) }
        }
        return (entries.sorted { $0.capture.startedAt > $1.capture.startedAt }, failures)
    }

    private struct PublicationCapture {
        let capture: DictationCapture
        let folder: URL
        let acknowledged: Set<String>
        let results: [URL]
    }

    private struct CaptureSummary: Sendable {
        let id: UUID
        let folder: URL
        let account: String?
        let startedAt: Date
        let finishedAt: Date?
        let originalByteCount: Int64?
        let sealed: Bool
        let published: Bool
        let hasOriginal: Bool
        let hasJournal: Bool

        func isPending(for account: String?) -> Bool {
            self.account != nil && self.account == account && sealed && !published
        }
    }

    private struct LoadedIndex: Sendable {
        let summaries: [String: CaptureSummary]
        let failures: [String: DictationLibraryError]
    }

    private func indexedCaptures() async throws -> [CaptureSummary] {
        if index == nil {
            let load = indexLoad ?? Task { [files, chunkBytes] in try await Self.loadIndex(files: files, chunkBytes: chunkBytes) }
            indexLoad = load
            let loaded: LoadedIndex
            do { loaded = try await load.value } catch {
                if indexLoad == load { indexLoad = nil }
                throw error
            }
            if indexLoad == load { indexLoad = nil }
            if index == nil {
                index = loaded.summaries
                readFailures = loaded.failures
            }
        }
        try refreshStaleEntries()
        guard let index else { preconditionFailure("The capture index is loaded before it is read") }
        return Array(index.values)
    }

    private func refreshStaleEntries() throws {
        guard let current = index else { return }
        var folders = Set(readFailures.keys)
        for (path, summary) in current where !summary.sealed { folders.insert(path) }
        if !staleCaptures.isEmpty {
            for partition in try Self.partitions(in: files) {
                for id in staleCaptures { folders.insert(partition.appending(path: id.uuidString, directoryHint: .isDirectory).path) }
            }
            staleCaptures.removeAll()
        }
        for path in folders { reread(path) }
    }

    private func reread(_ path: String) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: path) else {
            index?[path] = nil
            readFailures[path] = nil
            return
        }
        do {
            index?[path] = try Self.summary(of: folder, files: files, chunkBytes: chunkBytes)
            readFailures[path] = nil
        } catch {
            index?[path] = nil
            readFailures[path] = DictationLibraryError(error)
        }
    }

    @concurrent private static func loadIndex(files: LibraryFiles, chunkBytes: Int) async throws -> LoadedIndex {
        var summaries: [String: CaptureSummary] = [:]
        var failures: [String: DictationLibraryError] = [:]
        for partition in try partitions(in: files) {
            for folder in try captureFolders(in: partition) {
                do { summaries[folder.path] = try summary(of: folder, files: files, chunkBytes: chunkBytes) }
                catch { failures[folder.path] = DictationLibraryError(error) }
            }
        }
        return LoadedIndex(summaries: summaries, failures: failures)
    }

    private static func partitions(in files: LibraryFiles) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: files.root.path).compactMap { name in
            let partition = files.root.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: partition.path, isDirectory: &isDirectory) && isDirectory.boolValue ? partition : nil
        }
    }

    private static func captureFolders(in partition: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: partition.path).compactMap { name in
            UUID(uuidString: name) == nil ? nil : partition.appending(path: name, directoryHint: .isDirectory)
        }
    }

    private static func summary(of folder: URL, files: LibraryFiles, chunkBytes: Int) throws -> CaptureSummary {
        let item = try publication(at: folder, files: files)
        let capture = item.capture
        return CaptureSummary(id: capture.id, folder: folder, account: capture.account?.accountIdentifier,
            startedAt: capture.startedAt, finishedAt: capture.finishedAt, originalByteCount: capture.originalByteCount,
            sealed: capture.originalSHA256 != nil, published: isPublished(item, chunkBytes: chunkBytes),
            hasOriginal: FileManager.default.fileExists(atPath: folder.appending(path: "original.caf").path),
            hasJournal: FileManager.default.fileExists(atPath: folder.appending(path: "journal").path))
    }

    private static func publication(at folder: URL, files: LibraryFiles) throws -> PublicationCapture {
        let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        if let account = capture.account?.accountIdentifier,
           folder.standardizedFileURL != files.folder(capture.id, account: account).standardizedFileURL {
            throw DictationLibraryError.invalidCapture(capture.id)
        }
        return try PublicationCapture(capture: capture, folder: folder, acknowledged: acknowledgements(folder), results: LibraryFiles.resultFiles(in: folder))
    }

    private static func chunkNames(_ id: UUID, byteCount: Int64?, chunkBytes: Int) -> [String] {
        guard let count = byteCount, count > 0 else { return [] }
        return (0..<Int((count - 1) / Int64(chunkBytes) + 1)).map { DictationLibrarySchema.chunkName(id, index: $0) }
    }

    private static func isPublished(_ item: PublicationCapture, chunkBytes: Int) -> Bool {
        guard item.capture.originalSHA256 != nil, let count = item.capture.originalByteCount, count > 0 else { return false }
        let expected = [DictationLibrarySchema.captureName(item.capture.id)] + chunkNames(item.capture.id, byteCount: count, chunkBytes: chunkBytes)
            + item.results.map { DictationLibrarySchema.resultName(UUID(uuidString: $0.deletingPathExtension().lastPathComponent)!) }
        return Set(expected).isSubset(of: item.acknowledged)
    }

    public func status() async throws -> DictationPublicationStatus {
        let captures = try await indexedCaptures()
        let current = session?.accountIdentifier
        var pending = 0
        var held = 0
        var unverified = 0
        var releasable: Int64 = 0
        for capture in captures {
            if capture.account == nil { held += 1; unverified += 1 }
            else if capture.account != current { held += 1 }
            else if capture.isPending(for: current) { pending += 1 }
            else if capture.published, capture.hasOriginal { releasable += capture.originalByteCount ?? 0 }
        }
        let partitions = [files.partition(current).path, files.partition(nil).path]
        var messages: [UUID: DictationLibraryError] = [:]
        for source in [readFailures, entryFailures, recoveryFailures, publishFailures, reclaimFailures] {
            for (path, message) in source {
                let folder = URL(fileURLWithPath: path, isDirectory: true)
                guard partitions.contains(folder.deletingLastPathComponent().path), let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                messages[id] = message
            }
        }
        let failures = messages.map { DictationCaptureFailure(captureID: $0.key, error: $0.value) }.sorted { $0.captureID.uuidString < $1.captureID.uuidString }
        return DictationPublicationStatus(pendingCaptureCount: pending, heldCaptureCount: held, unverifiedCaptureCount: unverified, usedBytes: capacity.usedBytes, capacityBytes: capacity.limit, releasableBytes: releasable, failures: failures)
    }

    public func releasePublishedOriginals(finishedBefore cutoff: Date, session: DictationAccountSession) async throws -> DictationReleaseReport {
        let captures = try await capturesInPartition(of: session)
        var count = 0
        var bytes: Int64 = 0
        var retained = 0
        for capture in captures where capture.hasOriginal {
            guard capture.published, let finishedAt = capture.finishedAt, finishedAt < cutoff else { retained += 1; continue }
            guard let original = releasableOriginal(capture, account: session.accountIdentifier) else { continue }
            bytes += try release(original)
            count += 1
        }
        return DictationReleaseReport(releasedCount: count, releasedBytes: bytes, retainedUnpublishedCount: retained)
    }

    private func capturesInPartition(of lease: DictationAccountSession) async throws -> [CaptureSummary] {
        try validateAccountSession(lease)
        let partition = files.partition(lease.accountIdentifier).lastPathComponent
        let captures = try await indexedCaptures().filter { $0.folder.deletingLastPathComponent().lastPathComponent == partition }
        try validateAccountSession(lease)
        return captures
    }

    private func releasableOriginal(_ summary: CaptureSummary, account: String) -> URL? {
        staleCaptures.insert(summary.id)
        guard let item = try? Self.publication(at: summary.folder, files: files), item.capture.account?.accountIdentifier == account,
              Self.isPublished(item, chunkBytes: chunkBytes) else { return nil }
        let original = summary.folder.appending(path: "original.caf")
        return FileManager.default.fileExists(atPath: original.path) ? original : nil
    }

    private func release(_ original: URL) throws -> Int64 {
        try capacity.writeBeyondLimit(ReleaseMarker(releasedAt: .now), to: original.deletingLastPathComponent().appending(path: Self.releaseMarker))
        let size = Int64(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try RecordingFileSystem.remove(original)
        capacity.release(size)
        return size
    }

    private func reclaimPublishedOriginals(lease: DictationAccountSession) async throws {
        var failures: [String: DictationLibraryError] = [:]
        defer { reclaimFailures = failures }
        let retainedBytes = capacity.limit / 2
        guard capacity.usedBytes > retainedBytes else { return }
        var remaining = try await indexedCaptures()
            .filter { $0.account == lease.accountIdentifier && $0.published && $0.hasOriginal }
            .sorted { $0.startedAt < $1.startedAt }[...]
        while capacity.usedBytes > retainedBytes, !remaining.isEmpty, !publishAgain {
            var batch: [(item: CaptureSummary, names: [String])] = []
            var batchBytes: Int64 = 0
            while batchBytes < capacity.usedBytes - retainedBytes, let item = remaining.popFirst() {
                batch.append((item, [DictationLibrarySchema.captureName(item.id)] + Self.chunkNames(item.id, byteCount: item.originalByteCount, chunkBytes: chunkBytes)))
                batchBytes += item.originalByteCount ?? 0
            }
            let missing: Set<CKRecord.ID>
            do { missing = try await cloud.missing(batch.flatMap(\.names).map { CKRecord.ID(recordName: $0, zoneID: DictationLibrarySchema.zone) }) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try validateAccountSession(lease)
                if DictationLibraryError(error).stopsPublication { throw Self.libraryError(error) }
                if let oldest = batch.first?.item {
                    failures[oldest.folder.path] = DictationLibraryError(error)
                }
                return
            }
            try validateAccountSession(lease)
            guard !receiptsReset, !publishAgain else { return }
            let missingNames = Set(missing.map(\.recordName))
            for (item, names) in batch {
                let folder = item.folder.path
                guard !names.contains(where: missingNames.contains) else {
                    failures[folder] = .cloudOriginalMissing
                    continue
                }
                guard capacity.usedBytes > retainedBytes, let original = releasableOriginal(item, account: lease.accountIdentifier) else { continue }
                do { _ = try release(original) } catch { failures[folder] = DictationLibraryError(error) }
            }
        }
    }

    @discardableResult public func reseedPublication(session: DictationAccountSession) async throws -> Int {
        let captures = try await capturesInPartition(of: session)
        if publishing { receiptsReset = true; publishAgain = true }
        var reset = 0
        for capture in captures {
            let receipts = capture.folder.appending(path: Self.acknowledgementFile)
            guard FileManager.default.fileExists(atPath: receipts.path) else { continue }
            staleCaptures.insert(capture.id)
            try capacity.remove(receipts)
            reset += 1
        }
        return reset
    }

    @discardableResult public func publishPending() async throws -> DictationPublicationStatus {
        guard !publishing else { publishAgain = true; return try await status() }
        publishing = true
        defer { publishing = false }
        do {
            repeat {
                publishAgain = false
                _ = try await recoverInterruptedCaptures()
                let lease = try await verifiedSession()
                receiptsReset = false
                let pending = try await indexedCaptures()
                    .filter { $0.isPending(for: lease.accountIdentifier) }
                    .sorted { $0.startedAt > $1.startedAt }
                for summary in pending {
                    try validateAccountSession(lease)
                    defer { staleCaptures.insert(summary.id) }
                    do {
                        let item = try Self.publication(at: summary.folder, files: files)
                        guard item.capture.account?.accountIdentifier == lease.accountIdentifier, item.capture.originalSHA256 != nil else { continue }
                        try await publishCapture(item, lease: lease)
                        publishFailures[summary.folder.path] = nil
                    } catch DictationLibraryError.accountChanged { throw DictationLibraryError.accountChanged }
                    catch is CancellationError { throw CancellationError() }
                    catch is ReceiptsReset { break }
                    catch {
                        let failure = DictationLibraryError(error)
                        if failure.stopsPublication { throw Self.libraryError(error) }
                        publishFailures[summary.folder.path] = failure
                    }
                }
                try validateAccountSession(lease)
                try await reclaimPublishedOriginals(lease: lease)
            } while publishAgain
            return try await status()
        } catch { throw Self.libraryError(error) }
    }

    private func publishCapture(_ item: PublicationCapture, lease: DictationAccountSession) async throws {
        let capture = item.capture
        guard let byteCount = capture.originalByteCount, byteCount > 0 else { throw DictationLibraryError.invalidCapture(capture.id) }
        let folder = item.folder
        var acknowledged = item.acknowledged
        let missingChunks = Self.chunkNames(capture.id, byteCount: byteCount, chunkBytes: chunkBytes).enumerated().filter { !acknowledged.contains($0.element) }
        let captureName = DictationLibrarySchema.captureName(capture.id)
        let original = folder.appending(path: "original.caf")
        let released = FileManager.default.fileExists(atPath: folder.appending(path: Self.releaseMarker).path) && !FileManager.default.fileExists(atPath: original.path)
        if !released, !missingChunks.isEmpty || !acknowledged.contains(captureName) {
            guard try await Self.originalMatches(original, byteCount: byteCount, sha256: capture.originalSHA256) else { throw DictationLibraryError.contentConflict(capture.id.uuidString) }
        }
        if !released, !missingChunks.isEmpty {
            for (index, name) in missingChunks {
                let staging = folder.appending(path: "upload-\(index).part")
                defer { try? FileManager.default.removeItem(at: staging) }
                let expected = Int(min(Int64(chunkBytes), byteCount - Int64(index) * Int64(chunkBytes)))
                guard let hash = try await Self.stageChunk(of: original, offset: UInt64(index) * UInt64(chunkBytes), byteCount: expected, to: staging) else {
                    throw DictationLibraryError.contentConflict(capture.id.uuidString)
                }
                let record = DictationLibrarySchema.record(type: DictationLibrarySchema.chunkRecordType, name: name, payload: Data(), hash: hash)
                record[DictationLibrarySchema.originalAssetKey] = CKAsset(fileURL: staging)
                try await publish(record, lease: lease, folder: folder, acknowledged: &acknowledged)
            }
        }
        if !acknowledged.contains(captureName) {
            let payload = try LibraryFiles.encode(capture.publishedForm)
            try await publish(DictationLibrarySchema.record(type: DictationLibrarySchema.captureRecordType, name: captureName, payload: payload, hash: LibraryFiles.hash(payload)), lease: lease, folder: folder, acknowledged: &acknowledged)
        }
        for url in item.results {
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)!
            let name = DictationLibrarySchema.resultName(id)
            guard !acknowledged.contains(name) else { continue }
            let data = try Data(contentsOf: url)
            let result = try LibraryFiles.decode(DictationResultVersion.self, from: data)
            guard result.id == id, result.captureID == capture.id else { throw DictationLibraryError.invalidRecord(name) }
            try await publish(DictationLibrarySchema.record(type: DictationLibrarySchema.resultRecordType, name: name, payload: data, hash: LibraryFiles.hash(data)), lease: lease, folder: folder, acknowledged: &acknowledged)
        }
    }

    private func publish(_ record: CKRecord, lease: DictationAccountSession, folder: URL, acknowledged: inout Set<String>) async throws {
        guard !acknowledged.contains(record.recordID.recordName) else { return }
        try validateAccountSession(lease)
        guard try await cloud.accountIdentifier() == lease.accountIdentifier else { accountDidChange(); throw DictationLibraryError.accountChanged }
        try validateAccountSession(lease)
        do { try await cloud.create(record) } catch { throw Self.libraryError(error) }
        guard accountSession() == lease else { throw DictationLibraryError.accountChanged }
        guard !receiptsReset else { throw ReceiptsReset() }
        acknowledged.insert(record.recordID.recordName)
        try capacity.write(acknowledged.sorted(), to: folder.appending(path: Self.acknowledgementFile))
    }

    private func verifiedSession() async throws -> DictationAccountSession {
        guard let lease = session else { throw DictationLibraryError.accountUnavailable }
        guard try await cloud.accountIdentifier() == lease.accountIdentifier else { accountDidChange(); throw DictationLibraryError.accountChanged }
        try validateAccountSession(lease)
        return lease
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

    private static func acknowledgements(_ folder: URL) throws -> Set<String> {
        let url = folder.appending(path: acknowledgementFile)
        return FileManager.default.fileExists(atPath: url.path) ? Set(try LibraryFiles.read([String].self, at: url)) : []
    }

    @concurrent private static func originalMatches(_ original: URL, byteCount: Int64, sha256: String?) async throws -> Bool {
        try Int64(original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == byteCount && LibraryFiles.hashFile(original) == sha256
    }

    @concurrent private static func stageChunk(of original: URL, offset: UInt64, byteCount: Int, to staging: URL) async throws -> String? {
        let input = try FileHandle(forReadingFrom: original)
        defer { try? input.close() }
        try input.seek(toOffset: offset)
        guard let bytes = try input.read(upToCount: byteCount), bytes.count == byteCount else { return nil }
        try bytes.write(to: staging, options: .atomic)
        return LibraryFiles.hash(bytes)
    }

    private struct ReleaseMarker: Codable { let releasedAt: Date }
    private struct ReceiptsReset: Error {}
    private static let releaseMarker = "released.json"
    private static let acknowledgementFile = "published.json"
}
