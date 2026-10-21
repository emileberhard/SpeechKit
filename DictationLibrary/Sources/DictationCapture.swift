import Foundation

public struct DictationAccountStamp: Codable, Equatable, Sendable {
    public let accountIdentifier: String
    public let epoch: UUID

    public init(accountIdentifier: String, epoch: UUID) {
        self.accountIdentifier = accountIdentifier
        self.epoch = epoch
    }
}

public struct DictationCapture: Codable, Equatable, Sendable, Identifiable {
    public let formatVersion: Int
    public let id: UUID
    public internal(set) var account: DictationAccountStamp?
    public let source: String
    public let startedAt: Date
    public internal(set) var sampleRate: Int?
    public let plan: DictationPlan
    public internal(set) var finishedAt: Date?
    public internal(set) var interrupted: Bool
    public internal(set) var originalSHA256: String?
    public internal(set) var originalByteCount: Int64?

    var publishedForm: DictationCapture {
        var copy = self
        copy.account = nil
        return copy
    }
}

public enum DictationResultKind: String, Codable, Sendable {
    case providerOutput, cleanup, contextualOutput, answer, failure
}

public struct DictationResultVersion: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let captureID: UUID
    public let createdAt: Date
    public let kind: DictationResultKind
    public let text: String
    public let model: String
    public let contextWasUsed: Bool
    public let parentResultID: UUID?
    public let plan: DictationPlan

    public init(id: UUID, captureID: UUID, createdAt: Date, kind: DictationResultKind, text: String, model: String, contextWasUsed: Bool, parentResultID: UUID?, plan: DictationPlan) {
        self.id = id
        self.captureID = captureID
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.model = model
        self.contextWasUsed = contextWasUsed
        self.parentResultID = parentResultID
        self.plan = plan
    }
}

public struct DictationArchiveEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { capture.id }
    public let capture: DictationCapture
    public let results: [DictationResultVersion]
    public let originalURL: URL?
    public let published: Bool

    public init(capture: DictationCapture, results: [DictationResultVersion], originalURL: URL?, published: Bool) {
        self.capture = capture
        self.results = results
        self.originalURL = originalURL
        self.published = published
    }
}

public enum DictationCaptureOwnership: Equatable, Sendable {
    case unknown
    case current
    case otherAccount
    case held
}

public enum DictationHeldReason: Equatable, Sendable {
    case unverifiedPlan
    case otherAccount
}

public struct DictationHeldCapture: Equatable, Sendable, Identifiable {
    public var id: UUID { capture.id }
    public let capture: DictationCapture
    public let reason: DictationHeldReason
    public let originalURL: URL?
}

public struct DictationReleaseReport: Equatable, Sendable {
    public let releasedCount: Int
    public let releasedBytes: Int64
    public let retainedUnpublishedCount: Int
}
