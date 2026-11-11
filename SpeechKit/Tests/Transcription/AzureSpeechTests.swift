import Foundation
import Testing
@testable import SpeechKit

struct AzureSpeechTests {
    @Test func speakerAttributionRequestsBothLabelsAndWordTimes() throws {
        let (definition, _) = try AzureSpeechAPI.speakerDefinition(
            configuration: configuration(modelOptions: .init(transcribeStyle: .clean, timestamps: AzureSpeechModelOptions.Timestamps.none)),
            request: .init(languageHints: ["sv"], customVocabulary: ["SpeechKit"])
        )
        #expect(definition.diarization != nil)
        #expect(definition.enhancedMode?.modelOptions?.timestamps == .word)
        #expect(definition.enhancedMode?.modelOptions?.transcribeStyle == .clean)
        #expect(definition.locales == ["sv"])
        #expect(definition.phraseList?.phrases == ["SpeechKit"])
        let (ordinary, _) = try AzureSpeechAPI.definition(configuration: configuration(), request: .init())
        #expect(ordinary.diarization == nil)
    }

    @Test func speakerReplyDecodesTypedTimesWithoutLosingPhrases() throws {
        let data = Data(#"{"durationMilliseconds":3000,"combinedPhrases":[{"text":"Keep this. Background."}],"phrases":[{"speaker":0,"text":"Keep this.","words":[{"offsetMilliseconds":100,"durationMilliseconds":400},{"offsetMilliseconds":600,"durationMilliseconds":500}]},{"speaker":1,"text":"Background.","words":[{"offsetMilliseconds":1800,"durationMilliseconds":600}]}]}"#.utf8)
        let phrases = try JSONDecoder().decode(AzureSpeechAPI.SpeakerResponse.self, from: data).validatedPhrases()
        #expect(phrases == [
            SpeakerPhrase(speaker: 0, text: "Keep this.", words: [.milliseconds(100)..<Duration.milliseconds(500), .milliseconds(600)..<Duration.milliseconds(1100)]),
            SpeakerPhrase(speaker: 1, text: "Background.", words: [.milliseconds(1800)..<Duration.milliseconds(2400)])
        ])
    }

    @Test(arguments: [
        #"{"speaker":-1,"text":"Keep this.","words":[{"offsetMilliseconds":0,"durationMilliseconds":100}]}"#,
        #"{"speaker":0,"text":"Keep this.","words":[]}"#,
        #"{"speaker":0,"text":"Keep this.","words":[{"offsetMilliseconds":-1,"durationMilliseconds":100}]}"#,
        #"{"speaker":0,"text":"Keep this.","words":[{"offsetMilliseconds":0,"durationMilliseconds":0}]}"#,
        #"{"speaker":0,"text":"Keep this.","words":[{"offsetMilliseconds":900,"durationMilliseconds":101}]}"#,
        #"{"speaker":0,"text":"Keep this.","words":[{"offsetMilliseconds":9223372036854775807,"durationMilliseconds":1}]}"#,
        #"{"speaker":0,"text":"Partial.","words":[{"offsetMilliseconds":0,"durationMilliseconds":100}]}"#
    ])
    func malformedAttributionFailsRatherThanDroppingWords(phrase: String) throws {
        let data = Data("{\"durationMilliseconds\":1000,\"combinedPhrases\":[{\"text\":\"Keep this.\"}],\"phrases\":[\(phrase)]}".utf8)
        #expect(throws: SpeechKitError.self) {
            try JSONDecoder().decode(AzureSpeechAPI.SpeakerResponse.self, from: data).validatedPhrases()
        }
    }

    @Test(arguments: [50, 51, 57])
    func mai2BoundsProviderContextWithoutChangingTheCanonicalDictionary(count: Int) throws {
        let vocabulary = (1...count).map { "ProjectTerm\($0)" }
        let (definition, warnings) = try AzureSpeechAPI.definition(
            configuration: configuration(), request: .init(customVocabulary: vocabulary)
        )
        #expect(definition.phraseList?.phrases == Array(vocabulary.prefix(50)))
        #expect(vocabulary.count == count)
        #expect(warnings.count == (count > 50 ? 1 : 0))
    }

    @Test func mai2SkipsOversizedTermsBeforeTakingTheFirstFiftyCompatibleTerms() throws {
        let boundary = String(repeating: "x", count: 50)
        let vocabulary = [boundary, String(repeating: "x", count: 51), String(repeating: "e\u{301}", count: 26)]
            + (0..<51).map { "ProjectTerm\($0)" }
        let (definition, warnings) = try AzureSpeechAPI.definition(
            configuration: configuration(), request: .init(customVocabulary: vocabulary))
        #expect(definition.phraseList?.phrases == [boundary] + (0..<49).map { "ProjectTerm\($0)" })
        #expect(vocabulary.count == 54)
        #expect(warnings.count == 2)
    }

    @Test func modelOptionsAndVocabularyUseTheAzureSchema() throws {
        let configuration = try configuration(
            modelOptions: .init(transcribeStyle: .clean, timestamps: .word)
        )
        let (definition, warnings) = try AzureSpeechAPI.definition(
            configuration: configuration,
            request: .init(languageHints: ["en", "sv"], customVocabulary: [" SpeechKit ", "Stockholm", ""])
        )
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as? [String: Any])
        let enhanced = try #require(json["enhancedMode"] as? [String: Any])
        #expect(enhanced["model"] as? String == "MAI-Transcribe-2")
        #expect(enhanced["enabled"] as? Bool == true)
        #expect((enhanced["modelOptions"] as? [String: Any])?["transcribeStyle"] as? String == "clean")
        #expect(json["modelOptions"] == nil)
        #expect(json["locales"] == nil)
        #expect(warnings.count == 1)
        #expect((json["phraseList"] as? [String: Any])?["phrases"] as? [String] == ["SpeechKit", "Stockholm"])
    }

    @Test func modelIDsAreExtensibleAndDefaultFastOmitsEnhancedMode() throws {
        let (enhanced, _) = try AzureSpeechAPI.definition(
            configuration: configuration(model: .enhanced("future-model")), request: .init()
        )
        #expect(enhanced.enhancedMode?.model == "future-model")
        let (fast, _) = try AzureSpeechAPI.definition(configuration: configuration(model: .fast), request: .init())
        #expect(fast.enhancedMode == nil)
    }

    @Test func onlyLLMSpeechAcceptsInstructions() throws {
        #expect(throws: SpeechKitError.self) {
            try AzureSpeechAPI.definition(configuration: configuration(), request: .init(instructions: "Translate"))
        }
        let (definition, _) = try AzureSpeechAPI.definition(
            configuration: configuration(model: .llmSpeech), request: .init(instructions: "Use lexical format")
        )
        #expect(definition.enhancedMode?.prompt == ["Use lexical format"])
        #expect(definition.enhancedMode?.task == "transcribe")
    }

    @Test func singleLanguageIsAnExplicitOverride() throws {
        let (definition, warnings) = try AzureSpeechAPI.definition(
            configuration: configuration(), request: .init(languageHints: ["sv"])
        )
        #expect(definition.locales == ["sv"])
        #expect(warnings.isEmpty)
    }

    private func configuration(
        model: AzureSpeechModel = .maiTranscribe2,
        modelOptions: AzureSpeechModelOptions? = nil
    ) throws -> AzureSpeechProviderConfiguration {
        try .init(access: .testRouter(), model: model, modelOptions: modelOptions)
    }
}
