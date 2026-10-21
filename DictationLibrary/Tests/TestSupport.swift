import AVFAudio
import CloudKit
import Foundation
@testable import DictationLibrary

actor FakeCloud: LibraryCloud {
    private(set) var account: String?
    private(set) var profileValue: DictationProfile?
    private(set) var records: [String: CKRecord] = [:]
    private var log: [String] = []
    private var chunks: [String: Data] = [:]
    private(set) var createCount = 0
    private(set) var chunkFetches = 0
    private(set) var assetBytesDelivered = 0
    private(set) var requestedKeys: [[String]] = []
    private var profileFailure = false
    private var holdProfileRead = false
    private var heldProfileRead: CheckedContinuation<Void, Never>?
    private var profileReadStarted: CheckedContinuation<Void, Never>?
    private var zoneMissing = false
    private var corruptChunks = false
    let pageSize = 2

    init(account: String? = "account-a", profile: DictationProfile? = nil) {
        self.account = account
        profileValue = profile
    }

    func setAccount(_ value: String?) { account = value }
    func setProfile(_ value: DictationProfile?) { profileValue = value }
    func failProfile(_ value: Bool) { profileFailure = value }
    func deleteZone() { zoneMissing = true; records = [:]; log = [] }
    func corrupt(_ value: Bool) { corruptChunks = value }
    func replaceRecord(_ record: CKRecord) { records[record.recordID.recordName] = record }

    func accountIdentifier() async throws -> String? { account }

    func profile() async throws -> DictationProfile? {
        if profileFailure { throw CKError(.networkUnavailable) }
        let value = profileValue
        if holdProfileRead {
            holdProfileRead = false
            await withCheckedContinuation { heldProfileRead = $0; profileReadStarted?.resume(); profileReadStarted = nil }
        }
        return value
    }

    func holdNextProfileRead() { holdProfileRead = true }
    func waitUntilProfileReadHeld() async {
        if heldProfileRead != nil { return }
        await withCheckedContinuation { profileReadStarted = $0 }
    }
    func releaseProfileRead() { heldProfileRead?.resume(); heldProfileRead = nil }

    func saveProfile(_ profile: DictationProfile) async throws { profileValue = profile }

    func create(_ record: CKRecord) async throws {
        createCount += 1
        let name = record.recordID.recordName
        if let existing = records[name] {
            guard existing.encryptedValues["contentHash"] as? String == record.encryptedValues["contentHash"] as? String else {
                throw DictationLibraryError.contentConflict(name)
            }
            return
        }
        if let asset = record[DictationLibrarySchema.originalAssetKey] as? CKAsset, let url = asset.fileURL {
            chunks[name] = try Data(contentsOf: url)
        }
        records[name] = record
        log.append(name)
    }

    func changes(since token: Data?, desiredKeys: [String]) async throws -> LibraryCloudPage {
        requestedKeys.append(desiredKeys)
        if zoneMissing { throw LibraryCloudError.zoneMissing }
        let start = token.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        let end = min(log.count, start + pageSize)
        let page = try log[start..<end].map { name -> CKRecord in
            let source = records[name]!
            let projected = CKRecord(recordType: source.recordType, recordID: source.recordID)
            for key in desiredKeys {
                if key == DictationLibrarySchema.originalAssetKey, source[key] != nil {
                    assetBytesDelivered += chunks[name]?.count ?? 0
                } else if let value = source.encryptedValues[key] {
                    projected.encryptedValues[key] = value
                }
            }
            return projected
        }
        return LibraryCloudPage(records: page, deletedCount: 0, token: Data(String(end).utf8), moreComing: end < log.count)
    }

    func originalChunk(_ id: CKRecord.ID) async throws -> Data {
        chunkFetches += 1
        guard var data = chunks[id.recordName] else { throw DictationLibraryError.invalidRecord(id.recordName) }
        if corruptChunks, !data.isEmpty { data[0] ^= 0xFF }
        return data
    }

    func resultRecordNames() -> [String] { records.keys.filter { $0.hasPrefix("result-") }.sorted() }
}

enum TestSupport {
    static let profile = DictationProfile(archiveEnabled: true, preferredModel: "model-a", languages: ["sv", "en"], dictionary: ["Example"], cleanupEnabled: true, outputLanguage: nil, thinkingLevel: "low")

    static func capabilities() throws -> DictationCapabilities {
        try DictationCapabilities(models: ["model-a", "model-b"], fallbackModel: "model-b", supportsCleanup: true)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-library-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func store(_ directory: URL, cloud: FakeCloud, capacity: Int64 = 256 * 1_024 * 1_024, chunkBytes: Int = 16 * 1_024) throws -> DictationLibraryStore {
        try DictationLibraryStore(directory: directory, source: "test", capacityBytes: capacity, cloud: cloud, chunkBytes: chunkBytes)
    }

    static func archive(_ directory: URL, cloud: FakeCloud, capacity: Int64 = 256 * 1_024 * 1_024) throws -> DictationArchive {
        try DictationArchive(directory: directory, capacityBytes: capacity, cloud: cloud, chunkBytes: 16 * 1_024)
    }

    static func buffer(seconds: Double, sampleRate: Double = 44_100, seed: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) {
            let noise = Float.random(in: -0.2...0.2, using: &generator)
            buffer.floatChannelData![0][index] = 0.4 * sin(Float(index + seed) * 0.05) + noise
        }
        return buffer
    }

    static func capture(store: DictationLibraryStore, plan: DictationPlan, seconds: Double = 3) async throws -> DictationCapture {
        let writer = try await store.beginCapture(plan: plan)
        let audio = buffer(seconds: seconds)
        try writer.configure(format: audio.format)
        writer.append(audio)
        return try await writer.finish()
    }

    static func verifiedStore(_ directory: URL, cloud: FakeCloud, capacity: Int64 = 256 * 1_024 * 1_024) async throws -> DictationLibraryStore {
        let store = try store(directory, cloud: cloud, capacity: capacity)
        _ = try await store.refresh()
        return store
    }

    static func result(for capture: DictationCapture, text: String = "hello", kind: DictationResultKind = .providerOutput, id: UUID = UUID()) -> DictationResultVersion {
        DictationResultVersion(id: id, captureID: capture.id, createdAt: Date(timeIntervalSince1970: 1_800_000_000), kind: kind, text: text, model: "model-a", contextWasUsed: false, parentResultID: nil, plan: capture.plan)
    }
}
