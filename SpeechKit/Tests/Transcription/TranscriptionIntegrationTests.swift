import Foundation
import Testing
@testable import SpeechKit

@Suite("Batch transcription integration")
struct TranscriptionIntegrationTests {
    private struct Fixture {
        let fileName: String
        let anchors: [String]
        let minimumAnchorMatches: Int
    }

    private let fixtures: [Fixture] = [
        .init(
            fileName: "clip1_en_intro.mp3",
            anchors: ["hello", "speechkit", "integration", "tests"],
            minimumAnchorMatches: 2
        ),
        .init(
            fileName: "clip2_en_providers.mp3",
            anchors: ["openai", "assembly ai", "assemblyai", "eleven labs", "elevenlabs", "supports"],
            minimumAnchorMatches: 3
        ),
        .init(
            fileName: "clip3_sv_example.mp3",
            anchors: ["hej", "stockholm", "svensk", "transkribering", "speechkit"],
            minimumAnchorMatches: 2
        ),
        .init(
            fileName: "clip4_en_numbers.mp3",
            anchors: ["short", "audio", "four", "numbers", "42", "punctuation"],
            minimumAnchorMatches: 2
        ),
    ]

    private let languageHints = ["en", "sv"]
    private let customVocabulary = ["SpeechKit", "OpenAI", "AssemblyAI", "ElevenLabs", "Stockholm", "transkribering"]

    @Test func openAITranscriptionFixtures() async throws {
        try requireIntegrationEnabled()

        let provider = OpenAITranscriptionProvider(
            configuration: try OpenAIProviderConfiguration(
                access: IntegrationAccess.provider("openai"),
                model: "gpt-4o-mini-transcribe-2025-12-15"
            )
        )

        try await assertProvider(provider, providerName: "OpenAI", fixtures: fixtures)
    }

    @Test func assemblyAITranscriptionFixtures() async throws {
        try requireIntegrationEnabled()

        let provider = AssemblyAITranscriptionProvider(
            configuration: try AssemblyAIProviderConfiguration(
                access: IntegrationAccess.provider("assemblyai"),
                pollIntervalSeconds: 1.0
            )
        )

        try await assertProvider(provider, providerName: "AssemblyAI", fixtures: fixtures)
    }

    @Test func elevenLabsBatchTranscriptionFixtures() async throws {
        try requireIntegrationEnabled()

        let provider = ElevenLabsTranscriptionProvider(
            configuration: try ElevenLabsProviderConfiguration(
                access: IntegrationAccess.provider("elevenlabs")
            )
        )

        try await assertProvider(provider, providerName: "ElevenLabs batch", fixtures: fixtures)
    }

    @Test func geminiTranscriptionFixtures() async throws {
        try requireIntegrationEnabled()

        let provider = GeminiTranscriptionProvider(
            configuration: try GeminiProviderConfiguration(access: IntegrationAccess.provider("gemini"))
        )

        try await assertProvider(provider, providerName: "Gemini", fixtures: fixtures)
    }

    @Test func gemini35TranscribeFixtures() async throws {
        try requireIntegrationEnabled()

        let provider = GeminiTranscribeProvider(
            configuration: try GeminiTranscribeProviderConfiguration(
                access: IntegrationAccess.provider("gemini"),
                mode: .smart
            )
        )

        try await assertProvider(
            provider,
            providerName: "Gemini 3.5 Transcribe",
            fixtures: fixtures
        )
    }

    private func assertProvider(
        _ provider: any TranscriptionProvider,
        providerName: String,
        fixtures: [Fixture]
    ) async throws {
        let engine = TranscriptionEngine(provider: provider)

        for fixture in fixtures {
            let audioData = try loadFixtureData(fileName: fixture.fileName)
            let audio = try TranscriptionAudio(
                data: audioData,
                fileName: fixture.fileName,
                mimeType: "audio/mpeg",
                fileExtension: "mp3"
            )
            let request = TranscriptionRequest(
                audio: audio,
                languageHints: languageHints,
                customVocabulary: customVocabulary
            )

            let result = try await engine.transcribe(request)
            let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                !transcript.isEmpty,
                "\(providerName) returned empty text for fixture \(fixture.fileName)"
            )

            let score = anchorScore(actualText: transcript, anchors: fixture.anchors)
            #expect(
                score.matches >= fixture.minimumAnchorMatches,
                "\(providerName) weak transcript for fixture \(fixture.fileName). Matched \(score.matches)/\(score.totalAnchors) anchors. Transcript: \(transcript)"
            )
        }
    }

    private func loadFixtureData(fileName: String, filePath: String = #filePath) throws -> Data {
        let testsDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fixtureURL = testsDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Audio")
            .appendingPathComponent(fileName)

        return try Data(contentsOf: fixtureURL)
    }

    private func anchorScore(actualText: String, anchors: [String]) -> (matches: Int, totalAnchors: Int) {
        let transcriptTokens = normalizedTokens(actualText)
        var matches = 0

        for anchor in anchors {
            let anchorTokens = normalizedTokens(anchor)
            if !anchorTokens.isDisjoint(with: transcriptTokens) {
                matches += 1
            }
        }

        return (matches, anchors.count)
    }

    private func normalizedTokens(_ text: String) -> Set<String> {
        let cleanedCharacters = text.lowercased().unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let cleaned = String(cleanedCharacters)
        let tokens = cleaned
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return Set(tokens)
    }

    private func requireIntegrationEnabled() throws {
        let enabled = ProcessInfo.processInfo.environment["RUN_TRANSCRIPTION_INTEGRATION_TESTS"] == "1"
        if !enabled {
            try Test.cancel("Set RUN_TRANSCRIPTION_INTEGRATION_TESTS=1 to run paid-provider integration tests.")
        }
    }

}
