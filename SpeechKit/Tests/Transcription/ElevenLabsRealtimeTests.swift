import Foundation
import Testing
@testable import SpeechKit

struct ElevenLabsRealtimeTests {
    @Test func buildsRealtimeWebSocketRequest() async throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            keyterms: [" SpeechKit ", "Stockholm", ""],
            commitStrategy: .vad
        )
        let session = ElevenLabsRealtimeSession(
            configuration: configuration
        )

        let request = try await session.makeWebSocketRequest(languageCode: "sv")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []
        let items = Dictionary(uniqueKeysWithValues: queryItems.filter { $0.name != "keyterms" }.map { ($0.name, $0.value ?? "") })
        let keyterms = queryItems.filter { $0.name == "keyterms" }.map { $0.value ?? "" }

        #expect(url.scheme == "wss")
        #expect(items["model_id"] == "scribe_v2_realtime")
        #expect(items["audio_format"] == "pcm_16000")
        #expect(items["commit_strategy"] == "vad")
        #expect(items["include_timestamps"] == "true")
        #expect(items["language_code"] == "sv")
        #expect(keyterms == ["SpeechKit", "Stockholm"])
        #expect(url.host == "router.test")
        #expect(url.path == "/vendors/elevenlabs/v1/speech-to-text/realtime")
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer llmr_test"])
    }

    @Test func pinsTheOnlyPreferredLanguage() async throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: [" sv-SE ", "sv"]
        )
        let session = ElevenLabsRealtimeSession(configuration: configuration)

        let conditioning = configuration.languageConditioning()
        let request = try await session.makeWebSocketRequest(languageCode: conditioning.languageCode)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(configuration.languageHints == ["sv"])
        #expect(conditioning == ElevenLabsRealtimeLanguageConditioning(languageCode: "sv", previousText: nil))
        #expect(components.queryItems?.first { $0.name == "language_code" }?.value == "sv")
    }

    @Test func primesAutomaticDetectionForSeveralPreferredLanguages() async throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: ["sv", "en"]
        )
        let session = ElevenLabsRealtimeSession(configuration: configuration)

        let conditioning = configuration.languageConditioning()
        let request = try await session.makeWebSocketRequest(languageCode: conditioning.languageCode)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(conditioning.languageCode == nil)
        #expect(conditioning.previousText == "Vi pratar svenska and English.")
        #expect(components.queryItems?.contains { $0.name == "language_code" } == false)
    }

    @Test func buildsLanguageContextDynamically() throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: ["de", "fr"]
        )

        let conditioning = configuration.languageConditioning()

        #expect(conditioning.previousText == "Vi pratar Deutsch and français.")
        #expect(conditioning.previousText?.count ?? 0 < ElevenLabsRealtimeAPI.previousTextRecommendedLimit)
    }

    @Test func compactsLongLanguageContextWithoutSplittingCodes() throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: ["de", "fr", "es", "pt", "it", "nl", "da", "no", "fi", "pl", "cs", "tr"]
        )

        let previousText = try #require(configuration.languageConditioning().previousText)

        #expect(previousText == "de/fr/es/pt/it/nl/da/no/fi/pl/cs/tr")
        #expect(previousText.count < ElevenLabsRealtimeAPI.previousTextRecommendedLimit)
    }

    @Test func explicitLanguageOverrideTakesPrecedence() throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: ["sv", "en"]
        )

        let conditioning = configuration.languageConditioning(languageCode: " de ")

        #expect(conditioning == ElevenLabsRealtimeLanguageConditioning(languageCode: "de", previousText: nil))
    }

    @Test func validatesRealtimeKeytermLimits() throws {
        #expect(throws: SpeechKitError.self) {
            _ = try ElevenLabsRealtimeSessionConfiguration(
                access: .testRouter(),
                keyterms: Array(repeating: "term", count: 51)
            )
        }

        #expect(throws: SpeechKitError.self) {
            _ = try ElevenLabsRealtimeSessionConfiguration(
                access: .testRouter(),
                keyterms: ["twenty-one characters"]
            )
        }
    }

    @Test func buildsCompatibleRealtimeKeyterms() {
        let keyterms = ElevenLabsRealtimeSessionConfiguration.compatibleKeyterms(
            from: [" SpeechKit ", "", "twenty-one characters", "Stockholm"]
        )

        #expect(keyterms == ["SpeechKit", "Stockholm"])
    }

    @Test func buildsProviderAcceptedCommitMessage() async throws {
        let configuration = try ElevenLabsRealtimeSessionConfiguration(access: .testRouter())
        let session = ElevenLabsRealtimeSession(configuration: configuration)

        let message = try await session.makeCommitMessage()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )

        #expect(object["message_type"] as? String == "input_audio_chunk")
        #expect(object["audio_base_64"] as? String == "")
        #expect(object["commit"] as? Bool == true)
        #expect(object["sample_rate"] as? Int == 16_000)
    }

    @Test func decodesStableFinalTranscript() throws {
        let json = """
        {
          "message_type": "final_transcript",
          "text": "hej example"
        }
        """

        let event = try ElevenLabsRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .finalTranscript(let text) = event else {
            Issue.record("Expected stable final transcript")
            return
        }

        #expect(text == "hej example")
    }

    @Test func decodesCommittedTranscriptWithTimestamps() throws {
        let json = """
        {
          "message_type": "committed_transcript_with_timestamps",
          "text": "hej example",
          "language_code": "sv",
          "words": [
            {
              "text": "hej",
              "start": 0.0,
              "end": 0.2,
              "type": "word",
              "speaker_id": "speaker_0",
              "characters": [
                {
                  "text": "h",
                  "start": 0.0,
                  "end": 0.05
                },
                "e"
              ]
            }
          ]
        }
        """

        let event = try ElevenLabsRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .committedTranscriptWithTimestamps(let text, let languageCode, let words) = event else {
            Issue.record("Expected committed transcript with timestamps")
            return
        }

        #expect(text == "hej example")
        #expect(languageCode == "sv")
        #expect(words?.count == 1)
        #expect(words?.first?.speakerID == "speaker_0")
        #expect(words?.first?.characters?.count == 2)
        #expect(words?.first?.characters?.first?.text == "h")
    }

    @Test func decodesCommittedTranscriptWithNullWords() throws {
        let json = """
        {
          "message_type": "committed_transcript_with_timestamps",
          "text": "",
          "language_code": "sv",
          "words": null
        }
        """

        let event = try ElevenLabsRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .committedTranscriptWithTimestamps(let text, _, let words) = event else {
            Issue.record("Expected committed transcript with timestamps")
            return
        }

        #expect(text.isEmpty)
        #expect(words == nil)
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(from: event, includesTimestamps: true) == [.finalizationCompleted])
    }

    @Test func decodesSessionStarted() throws {
        let json = """
        {
          "message_type": "session_started",
          "session_id": "session_123",
          "config": {
            "sample_rate": 16000,
            "audio_format": "pcm_16000",
            "language_code": "en",
            "commit_strategy": "vad",
            "model_id": "scribe_v2_realtime",
            "include_timestamps": true
          }
        }
        """

        let event = try ElevenLabsRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .sessionStarted(let started) = event else {
            Issue.record("Expected session started event")
            return
        }

        #expect(started.sessionID == "session_123")
        #expect(started.sampleRate == 16_000)
        #expect(started.commitStrategy == .vad)
        #expect(started.includeTimestamps == true)
    }

    @Test func decodesServerErrors() throws {
        let json = """
        {
          "message_type": "rate_limited",
          "error": "Too many requests"
        }
        """

        #expect(throws: ElevenLabsRealtimeSessionError.self) {
            _ = try ElevenLabsRealtimeAPI.decodeEvent(from: Data(json.utf8))
        }
    }
}
