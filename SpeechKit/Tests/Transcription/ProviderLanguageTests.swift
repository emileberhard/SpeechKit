import Foundation
import Testing
@testable import SpeechKit

struct AssemblyAIRequestTests {
    @Test func acceptsServerSelectedCurrentModelPriority() throws {
        let configuration = try AssemblyAIProviderConfiguration(
            access: .testRouter(),
            pollIntervalSeconds: 0.1,
            speechModels: ["universal-3-5-pro"]
        )

        #expect(configuration.speechModels == ["universal-3-5-pro"])
        #expect(AssemblyAIProviderConfiguration.defaultSpeechModels == ["universal-3-5-pro", "universal-2"])
    }

    @Test func pinsSingleLanguageWithoutDetection() throws {
        let request = AssemblyAIAPI.TranscriptRequest(
            audio_url: "https://example.com/audio",
            speech_models: ["universal-3-5-pro", "universal-2"],
            language_code: "sv",
            language_detection: nil,
            language_detection_options: nil,
            keyterms_prompt: nil
        )

        let json = try encodedJSON(request)

        #expect(json["speech_models"] as? [String] == ["universal-3-5-pro", "universal-2"])
        #expect(json["language_code"] as? String == "sv")
        #expect(json["language_detection"] == nil)
        #expect(json["language_detection_options"] == nil)
        #expect(json["keyterms_prompt"] == nil)
    }

    @Test func detectsLanguageAmongExpectedLanguages() throws {
        let request = AssemblyAIAPI.TranscriptRequest(
            audio_url: "https://example.com/audio",
            speech_models: ["universal-3-5-pro", "universal-2"],
            language_code: nil,
            language_detection: true,
            language_detection_options: .init(expected_languages: ["en", "sv"]),
            keyterms_prompt: ["SpeechKit"]
        )

        let json = try encodedJSON(request)

        #expect(json["language_detection"] as? Bool == true)
        let options = try #require(json["language_detection_options"] as? [String: Any])
        #expect(options["expected_languages"] as? [String] == ["en", "sv"])
        #expect(json["keyterms_prompt"] as? [String] == ["SpeechKit"])
    }

    @Test func dropsKeytermsTheAPIWouldReject() {
        let keyterms = AssemblyAITranscriptionProvider.compatibleKeyterms(
            from: [" Stockholm ", "", "one two three four five six seven", "Blåfluff Fantasi"]
        )

        #expect(keyterms == ["Stockholm", "Blåfluff Fantasi"])
    }

    private func encodedJSON(_ request: AssemblyAIAPI.TranscriptRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct OpenAIRealtimeLanguageHintTests {
    @Test func promptsExpectedLanguagesWhenNoSingleLanguageIsPinned() throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            languageHints: ["en", "sv"]
        )

        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: nil)
        let transcription = payload.session.audio.input.transcription

        #expect(transcription.language == nil)
        #expect(transcription.prompt == "# Expected Languages\nen, sv")
    }

    @Test func pinsASingleLanguageHint() throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            languageHints: ["sv"]
        )

        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: nil)
        let transcription = payload.session.audio.input.transcription

        #expect(transcription.language == "sv")
        #expect(transcription.prompt == nil)
    }

    @Test func connectLanguageOverridesASingleLanguageHint() throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            languageHints: ["sv"]
        )

        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: "en")

        #expect(payload.session.audio.input.transcription.language == "en")
    }

    @Test func omitsLanguagePromptWhenLanguageCodeIsPinned() throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            languageHints: ["en", "sv"]
        )

        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: "sv")
        let transcription = payload.session.audio.input.transcription

        #expect(transcription.language == "sv")
        #expect(transcription.prompt == nil)
    }

    @Test func omitsLanguagePromptForModelsWithoutFreeTextPrompts() throws {
        for modelID in ["whisper-1", "gpt-realtime-whisper"] {
            let configuration = try OpenAIRealtimeSessionConfiguration(
                access: .testRouter(),
                modelID: modelID,
                languageHints: ["en", "sv"]
            )

            let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: nil)

            #expect(payload.session.audio.input.transcription.prompt == nil)
        }
    }
}
