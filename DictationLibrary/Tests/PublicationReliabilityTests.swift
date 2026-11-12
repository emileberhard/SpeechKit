import CloudKit
import Foundation
import Synchronization
import Testing
@testable import DictationLibrary

@Suite struct PublicationReliabilityTests {
    @Test func emptyResultsStayAvailableToLateWritersUntilReopening() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let plan = try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities())
        let writer = try await store.beginCapture(plan: plan)
        #expect(try await store.status().pendingCaptureCount == 0)
        await #expect(throws: DictationLibraryError.noAudio) { try await writer.finish() }
        let capture = try #require(try await store.capture(id: writer.id))
        try await store.addResult(TestSupport.result(for: capture, text: ""))
        #expect(try await store.publishPending().pendingCaptureCount == 0)
        try await store.addResult(TestSupport.result(for: capture, text: "late"))
        #expect(try await store.entries().first?.results.count == 2)
        let reopened = try await TestSupport.verifiedStore(directory, cloud: cloud)
        #expect(try await reopened.publishPending().pendingCaptureCount == 0)
        #expect(try await reopened.capture(id: writer.id) == nil)
        #expect(await cloud.createCount == 0)
    }

    @Test func aPassRemovesFinishedEmptyCapturesWithoutResults() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await TestSupport.verifiedStore(directory, cloud: FakeCloud(profile: TestSupport.profile))
        let writer = try await store.beginCapture(plan: store.makePlan(context: .chat, capabilities: TestSupport.capabilities()))
        await #expect(throws: DictationLibraryError.noAudio) { try await writer.finish() }
        _ = try await store.publishPending()
        #expect(try await store.capture(id: writer.id) == nil)
    }

    @Test func recoverySealsEvenWithoutAnAccountSession() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let id: UUID
        do {
            let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
            let writer = try await store.beginCapture(plan: store.makePlan(context: .chat, capabilities: TestSupport.capabilities()))
            let audio = TestSupport.buffer(seconds: 0.2)
            try writer.configure(format: audio.format)
            writer.append(audio)
            id = writer.id
        }
        let reopened = try TestSupport.store(directory, cloud: cloud)
        await #expect(throws: DictationLibraryError.accountUnavailable) { try await reopened.publishPending() }
        let folder = LibraryFiles(root: directory).folder(id, account: "account-a")
        let capture = try LibraryFiles.read(DictationCapture.self, at: folder.appending(path: "capture.json"))
        #expect(capture.originalSHA256 != nil)
        #expect(capture.interrupted)
    }

    @Test func readersOnlySeeCapturesAfterAudioAndBeforeResultsNewestFirst() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let plan = try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities())
        let older = try await TestSupport.capture(store: store, plan: plan, seconds: 0.2)
        let newer = try await TestSupport.capture(store: store, plan: plan, seconds: 0.2)
        let result = TestSupport.result(for: newer)
        try await store.addResult(result)
        await cloud.holdCreate(named: DictationLibrarySchema.captureName(newer.id))
        let pass = Task { try await store.publishPending() }
        await cloud.waitUntilCreateHeld()
        let reader = try TestSupport.archive(directory.appending(path: "reader"), cloud: cloud)
        try await reader.refresh()
        #expect(try await reader.entries().isEmpty)
        #expect(await cloud.records.keys.contains(DictationLibrarySchema.chunkName(newer.id, index: 0)))
        await cloud.releaseCreate()
        _ = try await pass.value
        let order = await cloud.createdNames()
        #expect(order.first == DictationLibrarySchema.chunkName(newer.id, index: 0))
        let capturePosition = try #require(order.firstIndex(of: DictationLibrarySchema.captureName(newer.id)))
        let resultPosition = try #require(order.firstIndex(of: DictationLibrarySchema.resultName(result.id)))
        let olderPosition = try #require(order.firstIndex(of: DictationLibrarySchema.chunkName(older.id, index: 0)))
        #expect(capturePosition < resultPosition && resultPosition < olderPosition)
        try await reader.refresh()
        let original = try await reader.original(for: newer.id)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func cancellationAfterCommitKeepsTheReceipt() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .chat, capabilities: TestSupport.capabilities()), seconds: 0.2)
        await cloud.holdCreate(named: DictationLibrarySchema.captureName(capture.id))
        let pass = Task { try await store.publishPending() }
        await cloud.waitUntilCreateHeld()
        pass.cancel()
        await cloud.releaseCreate()
        await #expect(throws: CancellationError.self) { try await pass.value }
        let creates = await cloud.createCount
        #expect(try await store.publishPending().pendingCaptureCount == 0)
        #expect(await cloud.createCount == creates)
    }

    @Test func aCancelledCloudKitRequestDoesNotBecomeACaptureFailure() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .chat, capabilities: TestSupport.capabilities()), seconds: 0.2)
        await cloud.failCreates(CKError(.operationCancelled))
        await cloud.holdCreate(named: DictationLibrarySchema.chunkName(capture.id, index: 0))
        let pass = Task { try await store.publishPending() }
        await cloud.waitUntilCreateHeld()
        pass.cancel()
        await cloud.releaseCreate()
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(try await store.status().failures.isEmpty)
        #expect(try await store.status().pendingCaptureCount == 1)
    }

    @Test func passFailuresDoNotStampCapturesAndConflictsDoNotBlockOtherCaptures() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let plan = try await store.makePlan(context: .chat, capabilities: TestSupport.capabilities())
        let healthy = try await TestSupport.capture(store: store, plan: plan, seconds: 0.2)
        let bad = try await TestSupport.capture(store: store, plan: plan, seconds: 0.2)
        await cloud.failCreates(CKError(.networkUnavailable))
        await #expect(throws: DictationLibraryError.cloudFailure(domain: CKErrorDomain, code: CKError.networkUnavailable.rawValue)) { try await store.publishPending() }
        #expect(await cloud.createCount == 1)
        #expect(try await store.status().failures.isEmpty)
        await cloud.failCreates(nil)
        await cloud.replaceRecord(DictationLibrarySchema.record(type: DictationLibrarySchema.chunkRecordType, name: DictationLibrarySchema.chunkName(bad.id, index: 0), payload: Data(), hash: "different"))
        let status = try await store.publishPending()
        #expect(status.pendingCaptureCount == 1)
        #expect(status.failures.map(\.captureID) == [bad.id])
        #expect(status.failures.first?.error == .contentConflict(DictationLibrarySchema.chunkName(bad.id, index: 0)))
        #expect(await cloud.records.keys.contains(DictationLibrarySchema.captureName(healthy.id)))
    }

    @Test func localReadFailuresKeepTheirDomainAndCode() async throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeCloud(profile: TestSupport.profile)
        let store = try await TestSupport.verifiedStore(directory, cloud: cloud)
        let capture = try await TestSupport.capture(store: store, plan: store.makePlan(context: .chat, capabilities: TestSupport.capabilities()), seconds: 0.2)
        let original = LibraryFiles(root: directory).folder(capture.id, account: "account-a").appending(path: "original.caf")
        try FileManager.default.removeItem(at: original)
        let status = try await store.publishPending()
        guard case .storageFailure(let domain, let code) = status.failures.first?.error else { Issue.record("Expected a storage failure"); return }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == CocoaError.fileReadNoSuchFile.rawValue)
    }
}

@Suite struct CloudKitPublicationRetryTests {
    @Test(arguments: [CKError.networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy])
    func transientCallsRetryWithServerDelay(code: CKError.Code) async throws {
        let attempts = Mutex(0)
        let waits = Mutex<[Duration]>([])
        let retry = CloudKitRetry(sleep: { delay in waits.withLock { $0.append(delay) } }, jitter: { 1 })
        let value = try await retry.run {
            let count = attempts.withLock { $0 += 1; return $0 }
            if count < 3 { throw CKError(code, userInfo: [CKErrorRetryAfterKey: 2.0]) }
            return 42
        }
        #expect(value == 42)
        #expect(waits.withLock { $0 } == [.seconds(2), .seconds(2)])
    }

    @Test(arguments: [CKError.networkUnavailable, .notAuthenticated])
    func unavailableCallsDoNotRetry(code: CKError.Code) async throws {
        let attempts = Mutex(0)
        let retry = CloudKitRetry(sleep: { _ in Issue.record("Unexpected retry") }, jitter: { 1 })
        await #expect(throws: CKError.self) {
            try await retry.run { attempts.withLock { $0 += 1 }; throw CKError(code) }
        }
        #expect(attempts.withLock { $0 } == 1)
    }

    @Test func retriesAreBoundedAndCancellationEndsSleep() async throws {
        let waits = Mutex<[Duration]>([])
        let retry = CloudKitRetry(sleep: { delay in waits.withLock { $0.append(delay) } }, jitter: { 1 })
        await #expect(throws: CKError.self) { try await retry.run { throw CKError(.networkFailure) } }
        #expect(waits.withLock { $0 } == [.seconds(1), .seconds(2)])
        waits.withLock { $0 = [] }
        await #expect(throws: CKError.self) { try await retry.run { throw CKError(.serviceUnavailable, userInfo: [CKErrorRetryAfterKey: 16.0]) } }
        #expect(waits.withLock { $0.isEmpty })
        let cancelled = CloudKitRetry(sleep: { _ in throw CancellationError() }, jitter: { 1 })
        await #expect(throws: CancellationError.self) { try await cancelled.run { throw CKError(.networkFailure) } }
    }

    @Test(arguments: [false, true])
    func equalHashConflictsAcknowledgeEvenInAnAtomicPartialFailure(partial: Bool) throws {
        let record = DictationLibrarySchema.record(type: DictationLibrarySchema.captureRecordType, name: "synthetic", payload: Data(), hash: "equal")
        let conflict = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: record])
        let error = partial ? CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [record.recordID: conflict]]) : conflict
        try CloudKitLibraryCloud.acknowledge(error, for: record)
        let different = DictationLibrarySchema.record(type: record.recordType, name: "synthetic", payload: Data(), hash: "different")
        #expect(throws: DictationLibraryError.contentConflict("synthetic")) { try CloudKitLibraryCloud.acknowledge(error, for: different) }
    }
}
