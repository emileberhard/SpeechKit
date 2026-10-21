import CryptoKit
import Foundation
import SpeechKit

struct LibraryFiles: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let value = try decoder.decode(type, from: data)
        if let capture = value as? DictationCapture, capture.formatVersion != 1 {
            throw DictationLibraryError.unsupportedVersion(capture.formatVersion)
        }
        return value
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hex(hash.finalize())
    }

    func partition(_ account: String?) -> URL {
        root.appending(path: account.map { Self.hash(Data($0.utf8)) } ?? "quarantine", directoryHint: .isDirectory)
    }

    func folder(_ id: UUID, account: String?) -> URL {
        partition(account).appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try RecordingFileSystem.createProtectedDirectory(url.deletingLastPathComponent())
        try RecordingFileSystem.replaceFile(url, with: encode(value))
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try decode(type, from: Data(contentsOf: url))
    }

    func captures(account: String?) throws -> [DictationCapture] {
        let directory = partition(account)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .map { try Self.read(DictationCapture.self, at: $0.appending(path: "capture.json")) }
    }

    static func results(in folder: URL) throws -> [DictationResultVersion] {
        try results(inDirectory: folder.appending(path: "results"))
    }

    static func results(inDirectory directory: URL) throws -> [DictationResultVersion] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try read(DictationResultVersion.self, at: $0) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    func usedBytes() throws -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
}
