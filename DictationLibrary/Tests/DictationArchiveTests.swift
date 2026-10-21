import CloudKit
import Foundation
import Testing
@testable import DictationLibrary

@Suite struct DictationArchiveTests {
    private struct Fixture {
        let directory: URL
        let cloud: FakeCloud
        let capture: DictationCapture
        let originalBytes: Data
        let archive: DictationArchive

        init() async throws {
            directory = try TestSupport.temporaryDirectory()
            cloud = FakeCloud(profile: TestSupport.profile)
            let store = try await TestSupport.verifiedStore(directory.appending(path: "producer"), cloud: cloud)
            capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()), seconds: 8)
            try await store.addResult(TestSupport.result(for: capture, text: "raw"))
            try await store.publishPending()
            let original = try #require(try await store.entries().first?.originalURL)
            originalBytes = try Data(contentsOf: original)
            archive = try TestSupport.archive(directory.appending(path: "archive"), cloud: cloud)
        }
    }

    @Test func metadataCatchUpDownloadsNoAudioBytes() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let report = try await fixture.archive.refresh()
        #expect(report.newCaptureCount == 1)
        #expect(report.newResultCount == 1)
        #expect(report.problems.isEmpty)
        #expect(await fixture.cloud.assetBytesDelivered == 0)
        #expect(await fixture.cloud.chunkFetches == 0)
        let requested = await fixture.cloud.requestedKeys
        #expect(requested.count > 1)
        #expect(requested.allSatisfy { $0 == DictationLibrarySchema.metadataKeys && !$0.contains(DictationLibrarySchema.originalAssetKey) })
        let entry = try #require(try await fixture.archive.entries().first)
        #expect(entry.originalURL == nil)
        #expect(entry.results.map(\.text) == ["raw"])
        let again = try await fixture.archive.refresh()
        #expect(again.newCaptureCount == 0 && again.newResultCount == 0)
    }

    @Test func malformedMetadataDoesNotConsumeTheChangeToken() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let name = DictationLibrarySchema.captureName(fixture.capture.id)
        let valid = try #require(await fixture.cloud.records[name])
        let malformed = CKRecord(recordType: valid.recordType, recordID: valid.recordID)
        await fixture.cloud.replaceRecord(malformed)
        await #expect(throws: DictationLibraryError.invalidRecord(name)) { try await fixture.archive.refresh() }
        let incomplete = try await fixture.archive.export(to: fixture.directory.appending(path: "exports"))
        #expect(!incomplete.manifest.freshness.catchUpReachedEnd)
        await fixture.cloud.replaceRecord(valid)
        let restarted = try TestSupport.archive(fixture.directory.appending(path: "archive"), cloud: fixture.cloud)
        try await restarted.refresh()
        #expect(try await restarted.entries().contains { $0.id == fixture.capture.id })
    }

    @Test func audioIsFetchedOnDemandAndVerified() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        let url = try await fixture.archive.original(for: fixture.capture.id)
        #expect(try Data(contentsOf: url) == fixture.originalBytes)
        #expect(await fixture.cloud.chunkFetches > 1)
        let fetches = await fixture.cloud.chunkFetches
        _ = try await fixture.archive.original(for: fixture.capture.id)
        #expect(await fixture.cloud.chunkFetches == fetches)
    }

    @Test func tamperedAudioIsRejectedAndLeavesNoFile() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        await fixture.cloud.corrupt(true)
        await #expect(throws: DictationLibraryError.contentConflict(fixture.capture.id.uuidString)) { try await fixture.archive.original(for: fixture.capture.id) }
        #expect(try await fixture.archive.entries().first?.originalURL == nil)
        await fixture.cloud.corrupt(false)
        _ = try await fixture.archive.original(for: fixture.capture.id)
    }

    @Test func replicaCapacityIsReportedNotExceeded() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        let root = fixture.directory.appending(path: "archive")
        let limit = try LibraryFiles(root: root).usedBytes() + Int64(fixture.originalBytes.count) - 1
        let small = try TestSupport.archive(root, cloud: fixture.cloud, capacity: limit)
        let report = try await small.retainAllOriginals()
        #expect(report.capacityExceeded)
        #expect(report.fetchedCount == 0)
        #expect(try await small.entries().first?.originalURL == nil)
    }

    @Test func restartedReplicaReservesMetadataBeforeWriting() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        _ = try await fixture.archive.retainAllOriginals()
        let root = fixture.directory.appending(path: "archive")
        let limit = try LibraryFiles(root: root).usedBytes() + 256
        let restarted = try TestSupport.archive(root, cloud: fixture.cloud, capacity: limit)
        let result = TestSupport.result(for: fixture.capture, text: String(repeating: "x", count: 1_024))
        do {
            try await restarted.addResult(result, session: producerSession(fixture))
            Issue.record("metadata must count existing originals against capacity")
        } catch DictationLibraryError.capacityExceeded {
            #expect(try LibraryFiles(root: root).usedBytes() <= limit)
        }
    }

    @Test func overlappingOriginalRequestsShareOneVerifiedDownload() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<12 {
                group.addTask { try await fixture.archive.original(for: fixture.capture.id) }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }
        #expect(urls.count == 12)
        #expect(Set(urls).count == 1)
        #expect(try Data(contentsOf: #require(urls.first)) == fixture.originalBytes)
        #expect(await fixture.cloud.chunkFetches == (fixture.originalBytes.count + 16_383) / 16_384)
    }

    @Test func exportIsSealedCompleteAndHardLinked() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let exports = fixture.directory.appending(path: "exports")
        try await fixture.archive.refresh()

        let partial = try await fixture.archive.export(to: exports)
        #expect(partial.manifest.complete == false)
        #expect(partial.manifest.completeness.missingAudioCaptureIDs == [fixture.capture.id])

        let replica = try await fixture.archive.retainAllOriginals()
        #expect(replica.fetchedCount == 1)
        let export = try await fixture.archive.export(to: exports)
        let manifest = export.manifest
        #expect(manifest.complete)
        #expect(manifest.formatVersion == 1)
        #expect(manifest.freshness.catchUpReachedEnd)
        #expect(manifest.completeness.captureCount == 1 && manifest.completeness.resultCount == 1 && manifest.completeness.audioPresentCount == 1)
        #expect(export.directory.deletingLastPathComponent().lastPathComponent == manifest.account.hash)
        #expect(!export.directory.lastPathComponent.hasPrefix("."))

        let audio = try #require(manifest.files.first { $0.path.hasSuffix("original.caf") })
        #expect(audio.sha256 == fixture.capture.originalSHA256)
        #expect(audio.byteCount == fixture.capture.originalByteCount)
        for file in manifest.files {
            let url = export.directory.appending(path: file.path)
            #expect(try LibraryFiles.hashFile(url) == file.sha256)
            #expect(Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1) == file.byteCount)
        }
        #expect(manifest.files.map(\.path).contains("captures/\(fixture.capture.id.uuidString)/capture.json"))
        let onDisk = try LibraryFiles.read(DictationExportManifest.self, at: export.directory.appending(path: "manifest.json"))
        #expect(onDisk.files == manifest.files && onDisk.complete == manifest.complete && onDisk.account == manifest.account && onDisk.completeness == manifest.completeness)
        #expect(abs(onDisk.createdAt.timeIntervalSince(manifest.createdAt)) < 0.001)

        let source = try #require(try await fixture.archive.entries().first?.originalURL)
        let linked = try FileManager.default.attributesOfItem(atPath: export.directory.appending(path: audio.path).path)[.systemFileNumber] as? Int
        let original = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? Int
        #expect(linked == original)

        _ = try await fixture.archive.export(to: exports)
        _ = try await fixture.archive.export(to: exports)
        let sealed = try FileManager.default.contentsOfDirectory(atPath: export.directory.deletingLastPathComponent().path)
        #expect(sealed.count == 2)
        #expect(sealed.allSatisfy { !$0.hasPrefix(".") })
    }

    @Test func cloudZoneDeletionRequiresDecisionAndKeepsTheReplica() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        _ = try await fixture.archive.retainAllOriginals()
        await fixture.cloud.deleteZone()
        await #expect(throws: DictationLibraryError.cloudDeletedRequiresDecision) { try await fixture.archive.refresh() }
        #expect(try await fixture.archive.entries().first?.originalURL != nil)
        let export = try await fixture.archive.export(to: fixture.directory.appending(path: "exports"))
        #expect(export.manifest.freshness.catchUpReachedEnd == false)
        #expect(export.manifest.complete == false)
    }

    @Test func explicitReseedRestoresOriginalsAndVersionsFromTheFullReplica() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        _ = try await fixture.archive.retainAllOriginals()
        let session = try await producerSession(fixture)
        await fixture.cloud.deleteZone()
        let restored = try await fixture.archive.reseedPublication(session: session)
        #expect(restored.captureCount == 1)
        #expect(restored.resultCount == 1)
        #expect(restored.originalCount == 1)
        #expect(restored.missingOriginalCaptureIDs.isEmpty)
        #expect(await fixture.cloud.records.keys.contains("capture-\(fixture.capture.id.uuidString)"))
        #expect(await fixture.cloud.resultRecordNames().count == 1)
    }

    @Test func accountSwitchUsesAnotherReplicaPartition() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.archive.refresh()
        await fixture.cloud.setAccount("account-b")
        #expect(try await fixture.archive.entries().isEmpty)
        await fixture.cloud.setAccount("account-a")
        #expect(try await fixture.archive.entries().count == 1)
        await fixture.cloud.setAccount(nil)
        await #expect(throws: DictationLibraryError.accountUnavailable) { try await fixture.archive.refresh() }
    }

    @Test func satelliteCaptureReceivesNewResultsWithoutDuplicatingTheOriginal() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = try await producerSession(fixture)
        try await fixture.archive.refresh()
        let createsBefore = await fixture.cloud.createCount
        let retranscription = TestSupport.result(for: fixture.capture, text: "again", kind: .cleanup)
        try await fixture.archive.addResult(retranscription, session: session)
        try await fixture.archive.publishPendingResults(session: session)
        #expect(await fixture.cloud.createCount == createsBefore + 1)
        #expect(await fixture.cloud.resultRecordNames().count == 2)
        try await fixture.archive.addResult(retranscription, session: session)
        #expect(await fixture.cloud.resultRecordNames().count == 2)
        #expect(try await fixture.archive.entries().first?.results.count == 2)

        let report = try await fixture.archive.refresh()
        #expect(report.newResultCount == 0)
        #expect(try await fixture.archive.entries().first?.results.count == 2)

        await #expect(throws: DictationLibraryError.contentConflict(retranscription.id.uuidString)) {
            try await fixture.archive.addResult(TestSupport.result(for: fixture.capture, text: "changed", kind: .cleanup, id: retranscription.id), session: session)
        }
        await #expect(throws: DictationLibraryError.invalidCapture(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)) {
            try await fixture.archive.addResult(DictationResultVersion(id: UUID(), captureID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, createdAt: .now, kind: .failure, text: "", model: "m", contextWasUsed: false, parentResultID: nil, plan: fixture.capture.plan), session: session)
        }
    }

    @Test func resultForAnotherVerifiedAccountIsRefused() async throws {
        let fixture = try await Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = try await producerSession(fixture)
        try await fixture.archive.refresh()
        await fixture.cloud.setAccount("account-b")
        let before = await fixture.cloud.createCount
        let result = TestSupport.result(for: fixture.capture)
        try await fixture.archive.addResult(result, session: session)
        await #expect(throws: DictationLibraryError.accountChanged) { try await fixture.archive.publishPendingResults(session: session) }
        #expect(await fixture.cloud.createCount == before)
        await fixture.cloud.setAccount("account-a")
        #expect(try await fixture.archive.entries().first?.results.contains(where: { $0.id == result.id }) == true)
    }

    private func producerSession(_ fixture: Fixture) async throws -> DictationAccountSession {
        let store = try await TestSupport.verifiedStore(fixture.directory.appending(path: "session"), cloud: fixture.cloud)
        return try #require(await store.accountSession())
    }
}
