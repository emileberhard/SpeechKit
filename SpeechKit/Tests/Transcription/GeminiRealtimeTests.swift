import Foundation
import Testing
@testable import SpeechKit

struct GeminiRealtimeTests {
    @Test func buildsAuthenticatedWebSocketRequest() async throws {
        let session = GeminiRealtimeSession(
            configuration: try GeminiRealtimeSessionConfiguration(access: .testRouter())
        )

        let request = try await session.makeWebSocketRequest()
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(url.scheme == "wss")
        #expect(url.host == "router.test")
        #expect(url.path == "/vendors/google/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
        #expect(components.queryItems == nil)
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer llmr_test"])
    }

    @Test func buildsSmartManualVADSetup() async throws {
        let session = GeminiRealtimeSession(
            configuration: try GeminiRealtimeSessionConfiguration(
                access: .testRouter(),
                customVocabulary: [" SpeechKit ", "Stockholm", ""],
                languageHints: ["sv", "en"],
                mode: .smart
            )
        )

        let message = try await session.makeSetupMessage(languageCode: nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let setup = try #require(object["setup"] as? [String: Any])
        let generation = try #require(setup["generationConfig"] as? [String: Any])
        let realtime = try #require(setup["realtimeInputConfig"] as? [String: Any])
        let automaticVAD = try #require(realtime["automaticActivityDetection"] as? [String: Any])
        let transcription = try #require(setup["inputAudioTranscription"] as? [String: Any])

        #expect(setup["model"] as? String == "models/gemini-3.5-transcribe-live")
        #expect(generation["responseModalities"] as? [String] == ["TEXT"])
        #expect(automaticVAD["disabled"] as? Bool == true)
        #expect(transcription["languageCodes"] as? [String] == ["sv-SE", "en-US"])
        #expect(transcription["customVocabulary"] as? [String] == ["SpeechKit", "Stockholm"])
        #expect(transcription["mode"] as? String == "SMART")
    }

    @Test func pinnedLanguageOverridesConfiguredHints() async throws {
        let session = GeminiRealtimeSession(
            configuration: try GeminiRealtimeSessionConfiguration(
                access: .testRouter(),
                languageHints: ["sv", "en"]
            )
        )

        let message = try await session.makeSetupMessage(languageCode: "sv")
        let object = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let setup = try #require(object["setup"] as? [String: Any])
        let transcription = try #require(setup["inputAudioTranscription"] as? [String: Any])

        #expect(transcription["languageCodes"] as? [String] == ["sv-SE"])
    }

    @Test func buildsAudioAndActivityMessages() async throws {
        let session = GeminiRealtimeSession(
            configuration: try GeminiRealtimeSessionConfiguration(access: .testRouter())
        )

        let start = try await session.makeActivityStartMessage()
        let audio = try await session.makeAudioMessage(Data([0x01, 0x02]))
        let end = try await session.makeActivityEndMessage()

        #expect(start == #"{"realtimeInput":{"activityStart":{}}}"#)
        #expect(end == #"{"realtimeInput":{"activityEnd":{}}}"#)

        let object = try #require(JSONSerialization.jsonObject(with: Data(audio.utf8)) as? [String: Any])
        let realtime = try #require(object["realtimeInput"] as? [String: Any])
        let payload = try #require(realtime["audio"] as? [String: Any])
        #expect(payload["data"] as? String == Data([0x01, 0x02]).base64EncodedString())
        #expect(payload["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test func decodesSetupPartialAndCommittedEvents() throws {
        #expect(try GeminiRealtimeAPI.decodeEvent(from: Data(#"{"setupComplete":{}}"#.utf8)) != nil)

        let partial = try GeminiRealtimeAPI.decodeEvent(
            from: Data(#"{"serverContent":{"interimInputTranscription":{"text":"Hej"}}}"#.utf8)
        )
        guard case .partialTranscript(let partialText) = partial else {
            Issue.record("Expected partial transcript")
            return
        }
        #expect(partialText == "Hej")

        let committed = try GeminiRealtimeAPI.decodeEvent(
            from: Data(#"{"serverContent":{"inputTranscription":{"text":"Hej Stockholm."}}}"#.utf8)
        )
        guard case .committedTranscript(let committedText) = committed else {
            Issue.record("Expected committed transcript")
            return
        }
        #expect(committedText == "Hej Stockholm.")
    }

    @Test func surfacesServerErrors() {
        #expect(throws: GeminiRealtimeSessionError.self) {
            _ = try GeminiRealtimeAPI.decodeEvent(
                from: Data(#"{"error":{"code":429,"message":"Rate limited","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
            )
        }
    }
}
