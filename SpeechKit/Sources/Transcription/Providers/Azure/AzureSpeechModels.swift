import Foundation

public enum AzureSpeechModel: Sendable, Equatable {
    case fast
    case llmSpeech
    case enhanced(String)

    public static let maiTranscribe2: Self = .enhanced("MAI-Transcribe-2")
    public static let maiTranscribe15: Self = .enhanced("MAI-Transcribe-1.5")

    /// Observed on the live MAI-2 endpoint: 51+ context items return HTTP 400.
    public var maximumVocabularyTerms: Int? {
        modelID?.caseInsensitiveCompare("MAI-Transcribe-2") == .orderedSame ? 50 : nil
    }

    var maximumVocabularyTermCharacters: Int? {
        modelID?.caseInsensitiveCompare("MAI-Transcribe-2") == .orderedSame ? 50 : nil
    }

    var modelID: String? {
        if case .enhanced(let id) = self { id } else { nil }
    }
}

public struct AzureSpeechModelOptions: Encodable, Sendable {
    public enum TranscriptionStyle: String, Encodable, Sendable {
        case verbatim
        case clean
    }

    public enum Timestamps: String, Encodable, Sendable {
        case none
        case segment
        case word
    }

    public let transcribeStyle: TranscriptionStyle?
    public let timestamps: Timestamps?

    public init(transcribeStyle: TranscriptionStyle? = nil, timestamps: Timestamps? = nil) {
        self.transcribeStyle = transcribeStyle
        self.timestamps = timestamps
    }
}

public struct AzureSpeechProviderConfiguration: Sendable {
    public let access: SpeechProviderAccess
    public let model: AzureSpeechModel
    public let apiVersion: String
    public let modelOptions: AzureSpeechModelOptions?
    public let diarization: Bool

    public init(
        access: SpeechProviderAccess,
        model: AzureSpeechModel = .maiTranscribe2,
        apiVersion: String = "2025-10-15",
        modelOptions: AzureSpeechModelOptions? = nil,
        diarization: Bool = false
    ) throws {
        if let modelID = model.modelID, modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SpeechKitError.invalidConfiguration("Azure Speech model ID is empty")
        }
        guard !apiVersion.isEmpty else {
            throw SpeechKitError.invalidConfiguration("Azure Speech API version is empty")
        }
        if modelOptions != nil, model.modelID == nil {
            throw SpeechKitError.invalidConfiguration("Model options require an enhanced Azure Speech model")
        }
        self.access = access
        self.model = model
        self.apiVersion = apiVersion
        self.modelOptions = modelOptions
        self.diarization = diarization
    }
}

enum AzureSpeechAPI {
    static let transcribePath = "/speechtotext/transcriptions:transcribe"
    static let sampleRate = 16_000
    static let maximumAudioBytes = 250_000_000 - 1

    struct Definition: Encodable {
        struct EnhancedMode: Encodable {
            let enabled = true
            let model: String?
            let task: String?
            let prompt: [String]?
            let modelOptions: AzureSpeechModelOptions?
        }
        struct PhraseList: Encodable { let phrases: [String] }
        struct Diarization: Encodable { let enabled = true }

        let enhancedMode: EnhancedMode?
        let phraseList: PhraseList?
        let locales: [String]?
        let diarization: Diarization?
    }

    struct TranscriptionResponse: Decodable {
        struct Phrase: Decodable { let text: String }
        let combinedPhrases: [Phrase]
    }

    static func definition(
        configuration: AzureSpeechProviderConfiguration,
        request: ProgressiveTranscriptionRequest
    ) throws -> (Definition, warnings: [String]) {
        let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let instructions, !instructions.isEmpty {
            guard configuration.model == .llmSpeech else {
                throw SpeechKitError.invalidRequest("This Azure Speech model does not support custom instructions")
            }
            guard instructions.count <= 20_000 else {
                throw SpeechKitError.invalidRequest("Azure LLM Speech instructions exceed 20,000 characters")
            }
        }
        let enhanced: Definition.EnhancedMode?
        switch configuration.model {
        case .fast:
            enhanced = nil
        case .llmSpeech:
            enhanced = .init(
                model: nil, task: "transcribe",
                prompt: instructions.flatMap { $0.isEmpty ? nil : [$0] }, modelOptions: nil
            )
        case .enhanced(let model):
            enhanced = .init(model: model, task: nil, prompt: nil, modelOptions: configuration.modelOptions)
        }
        let hints = CustomVocabulary.normalized(request.languageHints)
        let supportsMultipleHints = configuration.model == .fast
        let ignoredHints = hints.count > 1 && !supportsMultipleHints
        var warnings = ignoredHints
            ? ["This Azure Speech model uses automatic language detection when multiple language hints are supplied."]
            : []
        var phrases = CustomVocabulary.normalized(request.customVocabulary)
        if let limit = configuration.model.maximumVocabularyTermCharacters {
            let compatible = phrases.filter { $0.unicodeScalars.count <= limit }
            if compatible.count != phrases.count {
                warnings.append("This Azure Speech model accepts dictionary terms up to \(limit) characters; omitted \(phrases.count - compatible.count) longer terms. The supplied dictionary was not changed.")
            }
            phrases = compatible
        }
        if let limit = configuration.model.maximumVocabularyTerms, phrases.count > limit {
            warnings.append("This Azure Speech model accepts \(limit) dictionary terms; sent the first \(limit) of \(phrases.count). The supplied dictionary was not changed.")
            phrases = Array(phrases.prefix(limit))
        }
        return (
            Definition(
                enhancedMode: enhanced,
                phraseList: phrases.isEmpty ? nil : .init(phrases: phrases),
                locales: hints.isEmpty || ignoredHints ? nil : hints,
                diarization: configuration.diarization ? .init() : nil
            ),
            warnings
        )
    }
}
