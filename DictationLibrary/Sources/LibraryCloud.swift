import CloudKit
import Foundation
import Security

protocol LibraryCloud: Sendable {
    func accountIdentifier() async throws -> String?
    func profile() async throws -> DictationProfile?
    func saveProfile(_ profile: DictationProfile) async throws
    func create(_ record: CKRecord) async throws
    func changes(since token: Data?, desiredKeys: [String]) async throws -> LibraryCloudPage
    func originalChunk(_ id: CKRecord.ID) async throws -> Data
}

struct LibraryCloudPage: Sendable {
    let records: [CKRecord]
    let deletedCount: Int
    let token: Data
    let moreComing: Bool
}

enum LibraryCloudError: Error, Equatable, Sendable {
    case zoneMissing
    case tokenExpired
}

public enum DictationLibrarySchema {
    public static let zoneName = "TranscriptionHistory"
    public static let profileRecordType = "DictationProfile"
    public static let profileRecordName = "dictation-profile-v1"
    public static let captureRecordType = "DictationCapture"
    public static let resultRecordType = "DictationResultVersion"
    public static let chunkRecordType = "DictationOriginalChunk"
    public static let originalAssetKey = "asset"
    public static let metadataKeys = [payloadKey, contentHashKey]
    static let zone = CKRecordZone.ID(zoneName: zoneName)
    static let chunkBytes = 8 * 1_024 * 1_024

    public static let payloadKey = "payload"
    public static let contentHashKey = "contentHash"

    public static func schemaBootstrapRecords(assetDirectory: URL) throws -> [CKRecord] {
        let token = UUID().uuidString
        let asset = assetDirectory.appending(path: "schema-bootstrap-\(token).bin")
        try Data("bootstrap".utf8).write(to: asset)
        return [profileRecordType, captureRecordType, resultRecordType, chunkRecordType].map { type in
            let payload = Data("schema bootstrap".utf8)
            let record = record(type: type, name: "schema-bootstrap-\(token)-\(type)", payload: payload, hash: LibraryFiles.hash(payload))
            if type == chunkRecordType { record[originalAssetKey] = CKAsset(fileURL: asset) }
            return record
        }
    }

    static func record(type: String, name: String, payload: Data, hash: String) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zone))
        record.encryptedValues[payloadKey] = payload
        record.encryptedValues[contentHashKey] = hash
        return record
    }

    static func value<T: Decodable>(_ type: T.Type, from record: CKRecord) throws -> T {
        guard record.recordID.zoneID == zone, let payload = record.encryptedValues["payload"] as? Data,
              record.encryptedValues["contentHash"] as? String == LibraryFiles.hash(payload) else {
            throw DictationLibraryError.invalidRecord(record.recordID.recordName)
        }
        return try LibraryFiles.decode(type, from: payload)
    }

    static func captureName(_ id: UUID) -> String { "capture-\(id.uuidString)" }
    static func resultName(_ id: UUID) -> String { "result-\(id.uuidString)" }
    static func chunkName(_ id: UUID, index: Int) -> String { "original-\(id.uuidString)-\(index)" }
}

struct CloudKitLibraryCloud: LibraryCloud {
    private let containerIdentifier: String

    init(containerIdentifier: String) throws {
        guard !containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DictationLibraryError.invalidConfiguration
        }
        self.containerIdentifier = containerIdentifier
    }

    private var container: CKContainer {
        get throws {
            #if os(macOS)
            guard let task = SecTaskCreateFromSelf(nil),
                  let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
                  containers.contains(containerIdentifier) else { throw DictationLibraryError.accountUnavailable }
            #endif
            return CKContainer(identifier: containerIdentifier)
        }
    }

    private var database: CKDatabase { get throws { try container.privateCloudDatabase } }

    func accountIdentifier() async throws -> String? {
        switch try await container.accountStatus() {
        case .available: return try await container.userRecordID().recordName
        case .noAccount, .restricted: return nil
        default: throw DictationLibraryError.accountUnavailable
        }
    }

    func profile() async throws -> DictationProfile? {
        let record: CKRecord
        do { record = try await database.record(for: CKRecord.ID(recordName: DictationLibrarySchema.profileRecordName, zoneID: DictationLibrarySchema.zone)) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return nil }
        var profile = try DictationLibrarySchema.value(DictationProfile.self, from: record)
        var cursor: CKQueryOperation.Cursor?
        var terms: [(Date, String, String)] = []
        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor { page = try await database.records(continuingMatchFrom: cursor, desiredKeys: ["text", "normalizedText", "createdAt", "modifiedAt", "isDeleted"], resultsLimit: 200) }
            else { page = try await database.records(matching: CKQuery(recordType: "VocabularyEntry", predicate: NSPredicate(value: true)), inZoneWith: DictationLibrarySchema.zone, desiredKeys: ["text", "normalizedText", "createdAt", "modifiedAt", "isDeleted"], resultsLimit: 200) }
            for (id, result) in page.matchResults {
                let value = try result.get()
                guard let text = value.encryptedValues["text"] as? String,
                      let normalized = value.encryptedValues["normalizedText"] as? String,
                      let created = value.encryptedValues["createdAt"] as? Date,
                      let deleted = value.encryptedValues["isDeleted"] as? Bool,
                      id.recordName == "vocabulary-" + LibraryFiles.hash(Data(normalized.utf8)) else { throw DictationLibraryError.invalidRecord(id.recordName) }
                if !deleted { terms.append((created, id.recordName, text)) }
            }
            cursor = page.queryCursor
        } while cursor != nil
        profile.dictionary = terms.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        return profile
    }

    func saveProfile(_ profile: DictationProfile) async throws {
        let id = CKRecord.ID(recordName: DictationLibrarySchema.profileRecordName, zoneID: DictationLibrarySchema.zone)
        let record: CKRecord
        do { record = try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: DictationLibrarySchema.profileRecordType, recordID: id)
        }
        var preferences = profile
        preferences.dictionary = []
        let payload = try LibraryFiles.encode(preferences)
        record.encryptedValues["payload"] = payload
        record.encryptedValues["contentHash"] = LibraryFiles.hash(payload)
        _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true).saveResults[id]?.get()
    }

    func create(_ record: CKRecord) async throws {
        do {
            let response = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard let result = response.saveResults[record.recordID] else { throw DictationLibraryError.invalidRecord(record.recordID.recordName) }
            _ = try result.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let existing = error.serverRecord,
                  existing.recordType == record.recordType,
                  existing.encryptedValues["contentHash"] as? String == record.encryptedValues["contentHash"] as? String else {
                throw DictationLibraryError.contentConflict(record.recordID.recordName)
            }
        }
    }

    func changes(since token: Data?, desiredKeys: [String]) async throws -> LibraryCloudPage {
        let previous = try token.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }.flatMap { $0 }
        do {
            let page = try await database.recordZoneChanges(inZoneWith: DictationLibrarySchema.zone, since: previous, desiredKeys: desiredKeys, resultsLimit: 200)
            return try LibraryCloudPage(
                records: page.modificationResultsByID.values.map { try $0.get().record },
                deletedCount: page.deletions.count,
                token: NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true),
                moreComing: page.moreComing
            )
        } catch let error as CKError where error.code == .zoneNotFound {
            throw LibraryCloudError.zoneMissing
        } catch let error as CKError where error.code == .changeTokenExpired {
            throw LibraryCloudError.tokenExpired
        }
    }

    func originalChunk(_ id: CKRecord.ID) async throws -> Data {
        let record = try await database.record(for: id)
        guard record.recordType == DictationLibrarySchema.chunkRecordType,
              let asset = record[DictationLibrarySchema.originalAssetKey] as? CKAsset, let url = asset.fileURL else { throw DictationLibraryError.invalidRecord(id.recordName) }
        let bytes = try Data(contentsOf: url)
        guard record.encryptedValues["contentHash"] as? String == LibraryFiles.hash(bytes) else { throw DictationLibraryError.contentConflict(id.recordName) }
        return bytes
    }
}
