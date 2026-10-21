import Foundation

public enum DictationContext: String, Codable, Sendable {
    case prose, chat, terminal
}

public struct DictationProfile: Codable, Equatable, Sendable {
    public var archiveEnabled: Bool
    public var preferredModel: String
    public var languages: [String]
    public var dictionary: [String]
    public var cleanupEnabled: Bool
    public var outputLanguage: String?
    public var thinkingLevel: String

    public init(archiveEnabled: Bool, preferredModel: String, languages: [String], dictionary: [String], cleanupEnabled: Bool, outputLanguage: String?, thinkingLevel: String) {
        self.archiveEnabled = archiveEnabled
        self.preferredModel = preferredModel
        self.languages = languages
        self.dictionary = dictionary
        self.cleanupEnabled = cleanupEnabled
        self.outputLanguage = outputLanguage
        self.thinkingLevel = thinkingLevel
    }
}

public struct DictationCapabilities: Sendable {
    public let models: Set<String>
    public let fallbackModel: String
    public let supportsCleanup: Bool
    public let modelOptions: [String: [String: String]]

    public init(models: Set<String>, fallbackModel: String, supportsCleanup: Bool, modelOptions: [String: [String: String]] = [:]) throws {
        guard !fallbackModel.isEmpty, models.contains(fallbackModel) else { throw DictationLibraryError.invalidConfiguration }
        self.models = models
        self.fallbackModel = fallbackModel
        self.supportsCleanup = supportsCleanup
        self.modelOptions = modelOptions
    }
}

public struct DictationPlan: Codable, Equatable, Sendable {
    var accountSession: DictationAccountSession?
    public let context: DictationContext
    public let archiveEnabled: Bool
    public let preferredModel: String
    public let effectiveModel: String
    public let languages: [String]
    public let dictionary: [String]
    public let cleanupEnabled: Bool
    public let outputLanguage: String?
    public let thinkingLevel: String
    public let providerOptions: [String: String]
    public var usesFallbackModel: Bool { preferredModel != effectiveModel }

    public static func == (lhs: DictationPlan, rhs: DictationPlan) -> Bool {
        lhs.context == rhs.context && lhs.archiveEnabled == rhs.archiveEnabled && lhs.preferredModel == rhs.preferredModel && lhs.effectiveModel == rhs.effectiveModel
            && lhs.languages == rhs.languages && lhs.dictionary == rhs.dictionary && lhs.cleanupEnabled == rhs.cleanupEnabled
            && lhs.outputLanguage == rhs.outputLanguage && lhs.thinkingLevel == rhs.thinkingLevel && lhs.providerOptions == rhs.providerOptions
    }

    private enum CodingKeys: String, CodingKey {
        case context, archiveEnabled, preferredModel, effectiveModel, languages, dictionary, cleanupEnabled, outputLanguage, thinkingLevel, providerOptions
    }

    public init(unverifiedProfile profile: DictationProfile, context: DictationContext, capabilities: DictationCapabilities) {
        self.init(profile: profile, context: context, capabilities: capabilities, accountSession: nil)
    }

    init(profile: DictationProfile, context: DictationContext, capabilities: DictationCapabilities, accountSession: DictationAccountSession?) {
        self.accountSession = accountSession
        self.context = context
        archiveEnabled = profile.archiveEnabled
        preferredModel = profile.preferredModel
        effectiveModel = capabilities.models.contains(profile.preferredModel) ? profile.preferredModel : capabilities.fallbackModel
        languages = profile.languages
        dictionary = profile.dictionary
        cleanupEnabled = context != .terminal && profile.cleanupEnabled && capabilities.supportsCleanup
        outputLanguage = context == .terminal ? nil : profile.outputLanguage
        thinkingLevel = profile.thinkingLevel
        providerOptions = capabilities.modelOptions[effectiveModel] ?? [:]
    }
}

public struct DictationProfileSnapshot: Codable, Equatable, Sendable {
    public let accountIdentifier: String
    public let refreshedAt: Date
    public let profile: DictationProfile

    public init(accountIdentifier: String, refreshedAt: Date, profile: DictationProfile) {
        self.accountIdentifier = accountIdentifier
        self.refreshedAt = refreshedAt
        self.profile = profile
    }
}

public enum DictationLibraryError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration
    case accountUnavailable
    case accountChanged
    case profileUnavailable
    case archiveDisabled
    case capacityExceeded(limit: Int64, used: Int64)
    case invalidCapture(UUID)
    case contentConflict(String)
    case invalidRecord(String)
    case unsupportedVersion(Int)
    case noAudio
    case recordingFinished
    case cloudDeletedRequiresDecision
    case notConfigured
    case cloudFailure(String)
    case heldCapture(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The dictation library is configured incorrectly."
        case .accountUnavailable: "Sign in to iCloud to use the dictation library."
        case .accountChanged: "The iCloud account changed. Dictation work for the previous account is kept separately and will not be mixed into this one."
        case .profileUnavailable: "The dictation profile could not be loaded. Recordings are kept on this device until it can be verified."
        case .archiveDisabled: "Saving dictations to the library is turned off."
        case .notConfigured: "The dictation library has not been set up yet. Open SpeechKit to configure it."
        case .cloudFailure(let detail): "iCloud could not be reached (\(detail)). Saved dictations stay on this device and upload later."
        case .capacityExceeded(let limit, let used): "Dictation storage is full (\(used) of \(limit) bytes). Nothing was deleted; free space by releasing uploaded originals or raising the storage limit."
        case .invalidCapture: "This dictation is not in the library."
        case .contentConflict: "A different version of this item already exists. The original was kept."
        case .invalidRecord: "A library record failed verification and was ignored."
        case .unsupportedVersion(let version): "This data was written by a newer version (\(version)). Update the app."
        case .noAudio: "No audio was recorded."
        case .recordingFinished: "This recording has already finished."
        case .cloudDeletedRequiresDecision: "The iCloud library was deleted. The local archive is intact; choose whether to restore it to iCloud."
        case .heldCapture: "This dictation is held because its account is unverified or different. Review it before it is added to this account."
        }
    }
}
