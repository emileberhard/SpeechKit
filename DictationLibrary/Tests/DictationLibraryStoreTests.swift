import Foundation
import Testing
@testable import DictationLibrary

@Suite struct DictationLibraryStoreTests {
    @Test func aLateRefreshDoesNotUndoASavedPreference() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let session = try #require(await store.accountSession())
        await cloud.holdNextProfileRead()
        let refresh = Task { try await store.refresh() }
        await cloud.waitUntilProfileReadHeld()
        var updated = TestSupport.profile
        updated.preferredModel = "model-b"
        updated.languages = ["en"]
        try await store.saveProfile(updated, session: session)
        await cloud.releaseProfileRead()
        #expect(try await refresh.value?.profile == updated)
        #expect(try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities()).effectiveModel == "model-b")
        let restarted = try TestSupport.store(directory, cloud: cloud)
        await cloud.failProfile(true)
        #expect(try await restarted.refresh()?.profile == updated)
    }

    @Test func publicStoreCanRecordLocallyWithoutConstructingCloudKit() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DictationLibraryStore(directory: directory, source: "unsigned-local-test", capacityBytes: 4 * 1_024 * 1_024, containerIdentifier: "iCloud.com.example.Tests")
        let plan = DictationPlan(unverifiedProfile: TestSupport.profile, context: .chat, capabilities: try TestSupport.capabilities())
        _ = try await TestSupport.capture(store: store, plan: plan, seconds: 0.2)
        #expect(try await store.heldCaptures().count == 1)
        await #expect(throws: DictationLibraryError.accountUnavailable) { try await store.refresh() }
    }

    @Test func profileStatesStayDistinct() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capabilities = try TestSupport.capabilities()

        let unconfigured = FakeCloud(profile: nil)
        let store = try TestSupport.store(directory.appending(path: "a"), cloud: unconfigured)
        #expect(await store.profileState() == .unverified)
        await #expect(throws: DictationLibraryError.accountUnavailable) { try await store.makePlan(context: .prose, capabilities: capabilities) }
        #expect(try await store.refresh() == nil)
        #expect(await store.profileState() == .absent)
        await #expect(throws: DictationLibraryError.notConfigured) { try await store.makePlan(context: .prose, capabilities: capabilities) }

        let noAccount = FakeCloud(account: nil)
        let signedOut = try TestSupport.store(directory.appending(path: "b"), cloud: noAccount)
        await #expect(throws: DictationLibraryError.accountUnavailable) { try await signedOut.refresh() }

        let failing = FakeCloud(profile: TestSupport.profile)
        await failing.failProfile(true)
        let offline = try TestSupport.store(directory.appending(path: "c"), cloud: failing)
        do { _ = try await offline.refresh(); Issue.record("refresh should fail") }
        catch DictationLibraryError.cloudFailure {}
        await #expect(throws: DictationLibraryError.profileUnavailable) { try await offline.makePlan(context: .prose, capabilities: capabilities) }

        var disabled = TestSupport.profile
        disabled.archiveEnabled = false
        let optedOut = try TestSupport.store(directory.appending(path: "d"), cloud: FakeCloud(profile: disabled))
        _ = try await optedOut.refresh()
        let disabledPlan = try await optedOut.makePlan(context: .prose, capabilities: capabilities)
        #expect(disabledPlan.dictionary == TestSupport.profile.dictionary)
        #expect(!disabledPlan.archiveEnabled)
        await #expect(throws: DictationLibraryError.archiveDisabled) { try await optedOut.beginCapture(plan: disabledPlan) }
    }

    @Test func terminalPlanNeverRewritesProseAndFallbackIsRecorded() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = TestSupport.profile
        profile.preferredModel = "unavailable-model"
        profile.outputLanguage = "sv"
        let store = try TestSupport.store(directory, cloud: FakeCloud(profile: profile))
        _ = try await store.refresh()
        let terminal = try await store.makePlan(context: .terminal, capabilities: TestSupport.capabilities())
        #expect(terminal.cleanupEnabled == false)
        #expect(terminal.outputLanguage == nil)
        #expect(terminal.usesFallbackModel)
        #expect(terminal.effectiveModel == "model-b")
        #expect(terminal.preferredModel == "unavailable-model")
        let prose = try await store.makePlan(context: .prose, capabilities: TestSupport.capabilities())
        #expect(prose.cleanupEnabled)
        #expect(prose.outputLanguage == "sv")
    }

    @Test func canonicalLocalDictionaryIsAppliedWithoutASecondCloudWriter() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let session = try #require(await store.accountSession())
        try await store.updateDictionarySnapshot(["SampleApp", "Example Project"], session: session)
        let plan = try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities())
        #expect(plan.dictionary == ["SampleApp", "Example Project"])
        #expect(await cloud.profileValue?.dictionary == TestSupport.profile.dictionary)
    }

    @Test func explicitResetRecoveryRestoresTheAccountBoundCachedProfile() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let session = try #require(await store.accountSession())
        await cloud.setProfile(nil)
        _ = try await store.refresh()
        #expect(await store.profileState() == .absent)
        #expect(try await store.restoreCachedProfile(session: session))
        #expect(await cloud.profileValue?.preferredModel == TestSupport.profile.preferredModel)
    }

    @Test func publicationIsDeterministicAndIdempotentAcrossRestarts() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()), seconds: 6)
        try await store.addResult(TestSupport.result(for: capture))
        #expect(try await store.status().pendingCaptureCount == 1)

        try await store.publishPending()
        let firstNames = await cloud.records.keys.sorted()
        let firstCreates = await cloud.createCount
        #expect(firstNames.contains { $0.hasPrefix("capture-") })
        #expect(firstNames.filter { $0.hasPrefix("original-") }.count > 1)
        #expect(try await store.status().pendingCaptureCount == 0)

        try await store.publishPending()
        #expect(await cloud.createCount == firstCreates)

        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        try await restarted.publishPending()
        #expect(await cloud.createCount == firstCreates)
        #expect(await cloud.records.keys.sorted() == firstNames)

        try FileManager.default.removeItem(at: directory.appending(path: LibraryFiles(root: directory).partition("account-a").lastPathComponent).appending(path: "\(capture.id.uuidString)/published.json"))
        let replay = try await TestSupport.verifiedStore(directory, cloud: cloud)
        try await replay.publishPending()
        #expect(await cloud.records.keys.sorted() == firstNames)
    }

    @Test func crashKeepsTheSavedPrefix() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let id: UUID
        do {
            let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
            let plan = try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities())
            var writer: DictationCaptureWriter? = try await store.beginCapture(plan: plan)
            let audio = TestSupport.buffer(seconds: 2)
            try writer?.configure(format: audio.format)
            writer?.append(audio)
            writer?.append(audio)
            id = try #require(writer?.id)
            writer = nil
        }
        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let recovered = try await restarted.recoverInterruptedCaptures()
        let capture = try #require(recovered.first)
        #expect(capture.id == id)
        #expect(capture.interrupted)
        let sha = try #require(capture.originalSHA256)
        #expect(sha.count == 64)
        #expect(try await restarted.entries().first?.originalURL != nil)
        #expect(try await restarted.recoverInterruptedCaptures().isEmpty)
        try await restarted.publishPending()
        #expect(await cloud.records.keys.contains("capture-\(id.uuidString)"))
    }

    @Test func captureWithoutAudioLeavesNothingPending() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        _ = try await store.beginCapture(plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        _ = try await restarted.recoverInterruptedCaptures()
        #expect(try await restarted.status().pendingCaptureCount == 0)
    }

    @Test func staleAccountPlanIsRejected() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let plan = try await store.makePlan(context: .prose, capabilities: TestSupport.capabilities())
        await store.accountDidChange()
        await #expect(throws: DictationLibraryError.accountChanged) { try await store.beginCapture(plan: plan) }
        _ = try await store.refresh()
        await #expect(throws: DictationLibraryError.accountChanged) { try await store.beginCapture(plan: plan) }
        let fresh = try await store.makePlan(context: .prose, capabilities: TestSupport.capabilities())
        _ = try await store.beginCapture(plan: fresh)
    }

    @Test func unverifiedPlanIsHeldUntilExplicitlyReconciled() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let held = DictationPlan(unverifiedProfile: TestSupport.profile, context: .prose, capabilities: try TestSupport.capabilities())
        let capture = try await TestSupport.capture(store: store, plan: held)

        #expect(try await store.ownership(ofCapture: capture.id) == .held)
        #expect(try await store.entries().isEmpty)
        #expect(try await store.heldCaptures().map(\.id) == [capture.id])
        #expect(try await store.heldCaptures().first?.reason == .unverifiedPlan)
        #expect(try await store.status().heldCaptureCount == 1)
        try await store.publishPending()
        #expect(await cloud.createCount == 0)

        let lease = try #require(await store.accountSession())
        await store.accountDidChange()
        await #expect(throws: DictationLibraryError.accountChanged) { try await store.reconcileHeldCapture(id: capture.id, session: lease) }
        _ = try await store.refresh()
        let current = try #require(await store.accountSession())
        try await store.reconcileHeldCapture(id: capture.id, session: current)
        #expect(try await store.ownership(ofCapture: capture.id) == .current)
        #expect(try await store.heldCaptures().isEmpty)
        try await store.publishPending()
        #expect(await cloud.records.keys.contains("capture-\(capture.id.uuidString)"))
        await #expect(throws: DictationLibraryError.heldCapture(capture.id)) { try await store.reconcileHeldCapture(id: capture.id, session: current) }
    }

    @Test func lateResultStaysWithTheOriginalAccount() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        try await store.publishPending()

        await cloud.setAccount("account-b")
        await #expect(throws: DictationLibraryError.accountChanged) { try await store.refresh() }
        _ = try await store.refresh()
        #expect(await store.accountSession()?.accountIdentifier == "account-b")
        #expect(try await store.ownership(ofCapture: capture.id) == .otherAccount)

        let late = TestSupport.result(for: capture)
        try await store.addResult(late)
        #expect(try await store.entries().isEmpty)
        #expect(try await store.heldCaptures().first?.reason == .otherAccount)
        try await store.publishPending()
        #expect(await cloud.resultRecordNames().isEmpty)
        await #expect(throws: DictationLibraryError.heldCapture(capture.id)) { try await store.reconcileHeldCapture(id: capture.id, session: store.accountSession()!) }

        await cloud.setAccount("account-a")
        await #expect(throws: DictationLibraryError.accountChanged) { try await store.refresh() }
        _ = try await store.refresh()
        try await store.publishPending()
        #expect(await cloud.resultRecordNames() == ["result-\(late.id.uuidString)"])
    }

    @Test func resultVersionsAreImmutable() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await TestSupport.verifiedStore(directory, cloud: FakeCloud(profile: TestSupport.profile))
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        let id = UUID()
        try await store.addResult(TestSupport.result(for: capture, text: "one", id: id))
        try await store.addResult(TestSupport.result(for: capture, text: "one", id: id))
        await #expect(throws: DictationLibraryError.contentConflict(id.uuidString)) { try await store.addResult(TestSupport.result(for: capture, text: "two", id: id)) }
        #expect(try await store.entries().first?.results.count == 1)
        await #expect(throws: DictationLibraryError.invalidCapture(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)) {
            try await store.addResult(DictationResultVersion(id: UUID(), captureID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, createdAt: .now, kind: .failure, text: "", model: "m", contextWasUsed: false, parentResultID: nil, plan: capture.plan))
        }
    }

    @Test func capacityNeverEvictsUnpublishedOriginals() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud, capacity: 600_000)
        let plan = try await store.makePlan(context: .prose, capabilities: TestSupport.capabilities())
        let first = try await TestSupport.capture(store: store, plan: plan, seconds: 3)

        let status = try await store.status()
        #expect(status.releasableBytes == 0)
        let kept = try await store.releasePublishedOriginals(finishedBefore: .distantFuture, session: #require(await store.accountSession()))
        #expect(kept.releasedCount == 0)
        #expect(kept.retainedUnpublishedCount == 1)
        #expect(try await store.entries().first?.originalURL != nil)

        let writer = try await store.beginCapture(plan: plan)
        let audio = TestSupport.buffer(seconds: 3)
        try writer.configure(format: audio.format)
        for _ in 0..<4 { writer.append(audio) }
        do {
            _ = try await writer.finish()
            Issue.record("the capture should report the capacity failure")
        } catch let incomplete as IncompleteLibraryCapture {
            guard case DictationLibraryError.capacityExceeded(let limit, _)? = incomplete.cause as? DictationLibraryError else {
                Issue.record("unexpected cause \(incomplete.cause)")
                return
            }
            #expect(limit == 600_000)
            let journal = directory.appending(path: LibraryFiles(root: directory).partition("account-a").lastPathComponent)
                .appending(path: "\(incomplete.capture.id.uuidString)/journal/\(incomplete.capture.id.uuidString)/audio.pcm")
            #expect(FileManager.default.fileExists(atPath: journal.path))
        }
        let entries = try await store.entries()
        #expect(entries.contains { $0.id == first.id && $0.originalURL != nil })
    }

    @Test func acknowledgedOriginalsAreReleasedOnExplicitRequestAndLaterResultsStillPublish() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        try await store.publishPending()
        let before = try await store.status()
        #expect(before.releasableBytes == capture.originalByteCount)

        let early = try await store.releasePublishedOriginals(finishedBefore: Date(timeIntervalSince1970: 0), session: #require(await store.accountSession()))
        #expect(early.releasedCount == 0)
        let report = try await store.releasePublishedOriginals(finishedBefore: .distantFuture, session: #require(await store.accountSession()))
        #expect(report.releasedCount == 1)
        #expect(report.releasedBytes == capture.originalByteCount)
        let after = try await store.status()
        #expect(after.usedBytes < before.usedBytes)
        #expect(after.releasableBytes == 0)
        #expect(try await store.entries().first?.originalURL == nil)

        try await store.addResult(TestSupport.result(for: capture))
        try await store.publishPending()
        #expect(await cloud.resultRecordNames().count == 1)
        #expect(try await store.status().pendingCaptureCount == 0)
    }

    @Test func ownershipLookupSeparatesKnownArchiveIDsFromUnknown() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await TestSupport.verifiedStore(directory, cloud: FakeCloud(profile: TestSupport.profile))
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        #expect(try await store.ownership(ofCapture: capture.id) == .current)
        #expect(try await store.ownership(ofCapture: UUID()) == .unknown)
    }

    @Test func adoptionResumesAfterTheFolderWasMovedBeforeManifestCommit() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let plan = DictationPlan(unverifiedProfile: TestSupport.profile, context: .chat, capabilities: try TestSupport.capabilities())
        let capture = try await TestSupport.capture(store: store, plan: plan)
        let files = LibraryFiles(root: directory)
        let target = files.folder(capture.id, account: "account-a")
        try FileManager.default.moveItem(at: files.folder(capture.id, account: nil), to: target)
        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let session = try #require(await restarted.accountSession())
        try await restarted.reconcileHeldCapture(id: capture.id, session: session)
        #expect(try await restarted.ownership(ofCapture: capture.id) == .current)
        try await restarted.publishPending()
        #expect(await cloud.records.keys.contains("capture-\(capture.id.uuidString)"))
    }

    @Test func recoveryPreservesASealedOriginalWithoutItsFinalManifestFields() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        var capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        let expectedHash = capture.originalSHA256
        capture.originalSHA256 = nil
        capture.originalByteCount = nil
        let folder = LibraryFiles(root: directory).folder(capture.id, account: "account-a")
        try LibraryFiles.write(capture, to: folder.appending(path: "capture.json"))
        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        _ = try await restarted.recoverInterruptedCaptures()
        let recovered = try #require(try await restarted.entries().first)
        #expect(recovered.capture.originalSHA256 == expectedHash)
        #expect(recovered.originalURL != nil)
    }

    @Test func corruptCaptureDoesNotBlockHealthyPublication() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let healthy = try await TestSupport.capture(store: store, plan: store.makePlan(context: .prose, capabilities: TestSupport.capabilities()))
        let badID = UUID()
        let badFolder = LibraryFiles(root: directory).folder(badID, account: "account-a")
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: badFolder.appending(path: "capture.json"))
        let restarted = try await TestSupport.verifiedStore(directory, cloud: cloud)
        _ = try await restarted.recoverInterruptedCaptures()
        try await restarted.publishPending()
        #expect(await cloud.records.keys.contains("capture-\(healthy.id.uuidString)"))
        let failures = try await restarted.status().failures
        #expect(failures.map(\.captureID) == [badID])
        #expect(FileManager.default.fileExists(atPath: badFolder.path))
    }
}
