import Foundation
import Testing
@testable import SpeechKit

struct SpeechKitTests {
    @Test func buildsValidRequest() throws {
        let audio = try TranscriptionAudio(
            data: Data([0x00, 0x01]),
            fileName: "sample.m4a",
            mimeType: "audio/m4a",
            fileExtension: "m4a"
        )

        let request = TranscriptionRequest(
            audio: audio,
            languageHints: ["en", "sv"],
            customVocabulary: ["Example Project"]
        )

        #expect(request.languageHints.count == 2)
        #expect(request.customVocabulary.count == 1)
    }

    @Test func buildsCompatibleElevenLabsBatchKeyterms() {
        let longTerm = String(repeating: "a", count: 51)
        let tooManyWords = "one two three four five six"
        let keyterms = ElevenLabsTranscriptionProvider.compatibleKeyterms(
            from: [" SpeechKit ", "", longTerm, tooManyWords, "Stockholm"]
        )

        #expect(keyterms == ["SpeechKit", "Stockholm"])
    }
}
