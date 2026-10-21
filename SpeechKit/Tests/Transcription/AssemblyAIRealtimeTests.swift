import Foundation
import Testing
@testable import SpeechKit

struct AssemblyAIRealtimeTests {
    @Test func buildsCurrentStreamingRequest() async throws {
        let configuration = try AssemblyAIRealtimeSessionConfiguration(
            access: .testRouter(),
            keyterms: [" SpeechKit ", "Stockholm", ""],
            languageHints: ["sv-SE", "en"],
            prompt: "Personal dictation.",
            mode: .maximumAccuracy
        )
        let session = AssemblyAIRealtimeSession(
            configuration: configuration
        )

        let request = try await session.makeWebSocketRequest(languageCode: nil)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(url.scheme == "wss")
        #expect(url.host == "router.test")
        #expect(url.path == "/vendors/assemblyai-streaming/v3/ws")
        #expect(items["sample_rate"] == "16000")
        #expect(items["speech_model"] == "universal-3-5-pro")
        #expect(items["mode"] == "max_accuracy")
        #expect(items["language_codes"] == #"["sv","en"]"#)
        #expect(items["keyterms_prompt"] == #"["SpeechKit","Stockholm"]"#)
        #expect(items["prompt"] == "Personal dictation.")
        #expect(request.allHTTPHeaderFields == ["Authorization": "Bearer llmr_test"])
    }

    @Test func explicitLanguageOverrideTakesPrecedence() async throws {
        let configuration = try AssemblyAIRealtimeSessionConfiguration(
            access: .testRouter(),
            languageHints: ["sv", "en"]
        )
        let session = AssemblyAIRealtimeSession(configuration: configuration)

        let request = try await session.makeWebSocketRequest(languageCode: "de-DE")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.queryItems?.first { $0.name == "language_codes" }?.value == #"["de"]"#)
    }

    @Test func validatesAndFiltersRealtimeKeyterms() throws {
        #expect(throws: SpeechKitError.self) {
            _ = try AssemblyAIRealtimeSessionConfiguration(
                access: .testRouter(),
                keyterms: Array(repeating: "term", count: 101)
            )
        }
        #expect(throws: SpeechKitError.self) {
            _ = try AssemblyAIRealtimeSessionConfiguration(
                access: .testRouter(),
                keyterms: [String(repeating: "x", count: 51)]
            )
        }

        let compatible = AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(
            from: [" SpeechKit ", "", String(repeating: "x", count: 51), "Stockholm"]
        )
        #expect(compatible == ["SpeechKit", "Stockholm"])
    }

    @Test func buildsForceEndpointAndTerminateMessages() async throws {
        let session = AssemblyAIRealtimeSession(
            configuration: try AssemblyAIRealtimeSessionConfiguration(access: .testRouter())
        )

        #expect(try await session.makeCommitMessage() == #"{"type":"ForceEndpoint"}"#)
        #expect(try await session.makeTerminationMessage() == #"{"type":"Terminate"}"#)
    }

    @Test func decodesSessionTurnsAndTermination() throws {
        let begin = try AssemblyAIRealtimeAPI.decodeEvent(
            from: Data(#"{"type":"Begin","id":"session-1","expires_at":123,"configuration":{"model":"universal-3-5-pro"}}"#.utf8)
        )
        guard case .sessionStarted(let info) = begin else {
            Issue.record("Expected session start")
            return
        }
        #expect(info.sessionID == "session-1")
        #expect(info.appliedModelID == "universal-3-5-pro")

        let partial = try AssemblyAIRealtimeAPI.decodeEvent(
            from: Data(#"{"type":"Turn","turn_order":2,"end_of_turn":false,"transcript":"Hej"}"#.utf8)
        )
        guard case .partialTranscript(let partialOrder, let partialText) = partial else {
            Issue.record("Expected partial transcript")
            return
        }
        #expect(partialOrder == 2)
        #expect(partialText == "Hej")

        let committed = try AssemblyAIRealtimeAPI.decodeEvent(
            from: Data(#"{"type":"Turn","turn_order":2,"end_of_turn":true,"turn_is_formatted":true,"transcript":"Hej Stockholm."}"#.utf8)
        )
        guard case .committedTranscript(let committedOrder, let committedText) = committed else {
            Issue.record("Expected committed transcript")
            return
        }
        #expect(committedOrder == 2)
        #expect(committedText == "Hej Stockholm.")

        let termination = try AssemblyAIRealtimeAPI.decodeEvent(
            from: Data(#"{"type":"Termination","audio_duration_seconds":3.0,"session_duration_seconds":4.0}"#.utf8)
        )
        guard case .sessionTerminated(let summary) = termination else {
            Issue.record("Expected termination")
            return
        }
        #expect(summary.audioDurationSeconds == 3)
        #expect(summary.sessionDurationSeconds == 4)
    }

    @Test func surfacesServerErrors() {
        #expect(throws: AssemblyAIRealtimeSessionError.self) {
            _ = try AssemblyAIRealtimeAPI.decodeEvent(
                from: Data(#"{"type":"Error","error_code":3007,"error":"Audio transmission rate exceeded"}"#.utf8)
            )
        }
    }
}
