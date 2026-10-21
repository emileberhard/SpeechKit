import Foundation
import Testing
@testable import SpeechKit

struct OpenAIRealtimeTests {
    @Test func buildsRealtimeWebSocketRequest() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(access: .testRouter())
        let session = OpenAIRealtimeSession(
            configuration: configuration
        )

        let request = try await session.makeWebSocketRequest()
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(url.scheme == "wss")
        #expect(url.host == "router.test")
        #expect(url.path == "/vendors/openai/v1/realtime")
        #expect(items["intent"] == "transcription")
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer llmr_test"])
    }

    @Test func buildsSessionUpdateMessage() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            customVocabulary: [" SpeechKit ", "Stockholm", ""],
            sampleRate: 24_000,
            turnDetection: .serverVAD()
        )
        let session = OpenAIRealtimeSession(configuration: configuration)

        let message = try await session.makeSessionUpdateMessage(languageCode: "sv")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sessionObject = try #require(object["session"] as? [String: Any])
        let audio = try #require(sessionObject["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        let turnDetection = try #require(input["turn_detection"] as? [String: Any])

        #expect(object["type"] as? String == "session.update")
        #expect(sessionObject["type"] as? String == "transcription")
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["language"] as? String == "sv")
        #expect(transcription["prompt"] as? String == "# Dictionary / Common Words\n- SpeechKit\n- Stockholm")
        #expect(turnDetection["type"] as? String == "server_vad")
    }

    @Test func configuresRealtimeWhisperForHigherAccuracy() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-realtime-whisper",
            transcriptionDelay: .high,
            noiseReduction: .nearField
        )
        let session = OpenAIRealtimeSession(configuration: configuration)

        let message = try await session.makeSessionUpdateMessage(languageCode: "sv")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sessionObject = try #require(object["session"] as? [String: Any])
        let audio = try #require(sessionObject["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        let noiseReduction = try #require(input["noise_reduction"] as? [String: Any])

        #expect(transcription["model"] as? String == "gpt-realtime-whisper")
        #expect(transcription["delay"] as? String == "high")
        #expect(noiseReduction["type"] as? String == "near_field")
        #expect(input["turn_detection"] is NSNull)
    }

    @Test func configuresConservativeSemanticVAD() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            turnDetection: .semanticVAD(eagerness: .low),
            noiseReduction: .farField
        )
        let session = OpenAIRealtimeSession(configuration: configuration)

        let message = try await session.makeSessionUpdateMessage(languageCode: "sv")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sessionObject = try #require(object["session"] as? [String: Any])
        let audio = try #require(sessionObject["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])
        let turnDetection = try #require(input["turn_detection"] as? [String: Any])
        let noiseReduction = try #require(input["noise_reduction"] as? [String: Any])

        #expect(transcription["delay"] == nil)
        #expect(turnDetection["type"] as? String == "semantic_vad")
        #expect(turnDetection["eagerness"] as? String == "low")
        #expect(noiseReduction["type"] as? String == "far_field")
    }

    @Test func rejectsTurnDetectionForRealtimeWhisper() throws {
        #expect(throws: SpeechKitError.self) {
            try OpenAIRealtimeSessionConfiguration(
                access: .testRouter(),
                modelID: "gpt-realtime-whisper",
                turnDetection: .semanticVAD(eagerness: .low)
            )
        }
    }

    @Test func rejectsTranscriptionDelayForOtherModels() throws {
        #expect(throws: SpeechKitError.self) {
            try OpenAIRealtimeSessionConfiguration(
                access: .testRouter(),
                modelID: "gpt-4o-transcribe",
                transcriptionDelay: .high
            )
        }
    }

    @Test func includesCustomVocabularyPromptForSupportedModels() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: .testRouter(),
            modelID: "gpt-4o-mini-transcribe",
            customVocabulary: [" SpeechKit ", "Stockholm", ""]
        )
        let session = OpenAIRealtimeSession(configuration: configuration)

        let message = try await session.makeSessionUpdateMessage(languageCode: "en")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sessionObject = try #require(object["session"] as? [String: Any])
        let audio = try #require(sessionObject["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let transcription = try #require(input["transcription"] as? [String: Any])

        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["prompt"] as? String == "# Dictionary / Common Words\n- SpeechKit\n- Stockholm")
    }

    @Test func boundsTheCombinedPromptWithoutSplittingOrChangingCanonicalTerms() throws {
        let vocabulary = ["OpenAI", String(repeating: "x", count: 1_025), String(repeating: "e\u{301}", count: 600), "Stockholm"]
            + (0..<200).map { "ProjectTerm\($0)" }
        let configuration = try OpenAIRealtimeSessionConfiguration(access: .testRouter(),
            modelID: "gpt-4o-transcribe", customVocabulary: vocabulary, languageHints: ["en", "sv"])
        let payload = OpenAIRealtimeAPI.sessionUpdatePayload(configuration: configuration, languageCode: nil)
        let prompt = try #require(payload.session.audio.input.transcription.prompt)
        #expect(prompt.unicodeScalars.count <= 1_024)
        #expect(prompt.hasPrefix("# Expected Languages\nen, sv\n\n# Dictionary / Common Words\n- OpenAI\n- Stockholm"))
        #expect(!prompt.contains(String(repeating: "x", count: 1_025)))
        #expect(!prompt.contains("e\u{301}"))
        let sent = prompt.components(separatedBy: "\n- ").dropFirst()
        #expect(sent.allSatisfy { vocabulary.contains($0) })
        #expect(sent.count < vocabulary.count)
        #expect(configuration.customVocabulary == vocabulary)
    }

    @Test func disablesTurnDetectionByDefault() async throws {
        let configuration = try OpenAIRealtimeSessionConfiguration(access: .testRouter())
        let session = OpenAIRealtimeSession(configuration: configuration)

        let message = try await session.makeSessionUpdateMessage(languageCode: "en")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let sessionObject = try #require(object["session"] as? [String: Any])
        let audio = try #require(sessionObject["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])

        #expect(input["turn_detection"] is NSNull)
    }

    @Test func decodesTranscriptionDelta() throws {
        let json = """
        {
          "type": "conversation.item.input_audio_transcription.delta",
          "item_id": "item_123",
          "content_index": 0,
          "delta": "Hej"
        }
        """

        let event = try OpenAIRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .partialTranscript(let itemID, let delta) = event else {
            Issue.record("Expected partial transcript")
            return
        }

        #expect(itemID == "item_123")
        #expect(delta == "Hej")
    }

    @Test func decodesCompletedTranscript() throws {
        let json = """
        {
          "type": "conversation.item.input_audio_transcription.completed",
          "item_id": "item_123",
          "content_index": 0,
          "transcript": "Hej Stockholm."
        }
        """

        let event = try OpenAIRealtimeAPI.decodeEvent(from: Data(json.utf8))
        guard case .committedTranscript(let itemID, let transcript) = event else {
            Issue.record("Expected committed transcript")
            return
        }

        #expect(itemID == "item_123")
        #expect(transcript == "Hej Stockholm.")
    }

    @Test func ignoresUnrelatedEvents() throws {
        let json = """
        {
          "type": "conversation.item.created",
          "item": {"id": "item_123"}
        }
        """

        let event = try OpenAIRealtimeAPI.decodeEvent(from: Data(json.utf8))
        #expect(event == nil)
    }

    @Test func decodesVoiceActivityAndCommits() throws {
        let events = try [
            #"{"type":"input_audio_buffer.speech_started","audio_start_ms":0,"item_id":"item_1"}"#,
            #"{"type":"input_audio_buffer.speech_stopped","audio_end_ms":900,"item_id":"item_1"}"#,
            #"{"type":"input_audio_buffer.committed","previous_item_id":null,"item_id":"item_1"}"#,
        ].map { try OpenAIRealtimeAPI.decodeEvent(from: Data($0.utf8)) }

        guard case .speechStarted("item_1")? = events[0],
              case .speechStopped("item_1")? = events[1],
              case .audioCommitted("item_1")? = events[2] else {
            Issue.record("Unexpected events: \(events)")
            return
        }
    }

    @Test func commitErrorsBecomeRejectedCommitsAndOtherErrorsThrow() throws {
        let rejected = #"{"type":"error","error":{"type":"invalid_request_error","message":"buffer empty","event_id":"speechkit_commit"}}"#
        guard case .commitRejected? = try OpenAIRealtimeAPI.decodeEvent(from: Data(rejected.utf8)) else {
            Issue.record("Expected a rejected commit")
            return
        }
        let other = #"{"type":"error","error":{"type":"server_error","message":"boom","event_id":"other"}}"#
        #expect(throws: OpenAIRealtimeSessionError.self) { try OpenAIRealtimeAPI.decodeEvent(from: Data(other.utf8)) }
    }

    @Test func commitCarriesItsCorrelationID() throws {
        let data = try JSONEncoder().encode(OpenAIRealtimeAPI.CommitAudioPayload())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["type": "input_audio_buffer.commit", "event_id": OpenAIRealtimeAPI.commitEventID])
    }
}
