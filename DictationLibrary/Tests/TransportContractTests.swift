import CloudKit
import Foundation
import Testing
@testable import DictationLibrary

@Suite struct TransportContractTests {
    @Test func rejectsAnEmptyContainerBeforeCreatingLocalStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(throws: DictationLibraryError.invalidConfiguration) {
            try DictationLibraryStore(directory: directory, source: "test", capacityBytes: 1_024, containerIdentifier: "")
        }
        #expect(throws: DictationLibraryError.invalidConfiguration) {
            try DictationArchive(directory: directory, capacityBytes: 1_024, containerIdentifier: "  ")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func metadataFetchesNeverNameBinaryFields() {
        #expect(!DictationLibrarySchema.metadataKeys.contains(DictationLibrarySchema.originalAssetKey))
        #expect(!DictationLibrarySchema.metadataKeys.contains("audio"))
        #expect(Set(DictationLibrarySchema.metadataKeys) == ["payload", "contentHash"])
    }

    @Test func recordsUseOnlyDeclaredFieldsAndDeterministicNames() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let record = DictationLibrarySchema.record(type: DictationLibrarySchema.captureRecordType, name: DictationLibrarySchema.captureName(id), payload: Data("x".utf8), hash: "h")
        #expect(record.allKeys().sorted() == ["contentHash", "payload"])
        #expect(record.encryptedValues.allKeys().sorted() == ["contentHash", "payload"])
        #expect(record.recordID.zoneID.zoneName == "TranscriptionHistory")
        #expect(DictationLibrarySchema.chunkName(id, index: 3) == "original-00000000-0000-0000-0000-0000000000AA-3")
    }
}
