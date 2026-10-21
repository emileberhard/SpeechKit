import Foundation
import Testing
@testable import SpeechKit

@Suite(.timeLimit(.minutes(1)))
struct AzureSpeechIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_TRANSCRIPTION_INTEGRATION_TESTS"] == "1"))
    func mai2AcceptsCompletedAndProgressiveAudio() async throws {
        let provider = AzureSpeechTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("azure"), modelOptions: .init(transcribeStyle: .clean)
        ))
        let pcm = try FixtureAudio.pcm16("clip5_realtime_dictation_en.mp3", sampleRate: 16_000)
        let vocabulary = (1...57).map { "ProjectTerm\($0)" }
        let audio = try TranscriptionAudio(
            data: PCM16WAVFile.data(pcmData: pcm, sampleRate: 16_000),
            fileName: "fixture.wav", mimeType: "audio/wav", fileExtension: "wav"
        )
        let batch = try await provider.transcribe(.init(audio: audio, languageHints: ["en"], customVocabulary: vocabulary))
        try assertAnchors(batch.text)

        let upload = try await provider.startProgressiveTranscription(.init(languageHints: ["en", "sv"], customVocabulary: vocabulary))
        do {
            let started = ContinuousClock.now
            for offset in stride(from: 0, to: pcm.count, by: 3_200) {
                let end = min(offset + 3_200, pcm.count)
                try await Task.sleep(until: started.advanced(by: .seconds(Double(end) / 32_000)), clock: .continuous)
                try await upload.appendAudio(pcm.subdata(in: offset..<end))
            }
            let stopped = ContinuousClock.now
            let result = try await upload.finish()
            let tail = stopped.duration(to: .now).components
            let tailMilliseconds = Double(tail.seconds) * 1_000 + Double(tail.attoseconds) / 1e15
            print("Azure MAI-2 progressive upload: characters=\(result.text.count), finish-to-result-ms=\(Int(tailMilliseconds))")
            try assertAnchors(result.text)
            #expect(result.warnings.count == 2)
            await #expect(throws: ProgressiveTranscriptionError.alreadyFinished) { try await upload.finish() }
        } catch {
            await upload.cancel()
            throw error
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_TRANSCRIPTION_INTEGRATION_TESTS"] == "1"), arguments: [50, 51])
    func mai2AcceptsPersonalVocabularyLengthBoundary(length: Int) async throws {
        let provider = AzureSpeechTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("azure"), modelOptions: .init(transcribeStyle: .clean)
        ))
        let pcm = try FixtureAudio.pcm16("clip5_realtime_dictation_en.mp3", sampleRate: 16_000)
        let vocabulary = ["OpenAI", "AssemblyAI", "ElevenLabs", String(repeating: "x", count: length)]
            + (0..<101).map { "Term\($0)" }
        let audio = try TranscriptionAudio(data: PCM16WAVFile.data(pcmData: pcm, sampleRate: 16_000),
            fileName: "fixture.wav", mimeType: "audio/wav", fileExtension: "wav")
        let result = try await provider.transcribe(.init(audio: audio,
            languageHints: ["en", "sv"], customVocabulary: vocabulary))
        try assertAnchors(result.text)
        #expect(vocabulary.count == 105)
        #expect(result.warnings.count == (length == 50 ? 2 : 3))
    }

    private func assertAnchors(_ text: String) throws {
        let normalized = text.lowercased()
        let count = ["paste", "final", "sentence", "recording", "stop"].filter { normalized.contains($0) }.count
        #expect(count >= 4, "Azure returned too few fixture anchor words")
        #expect(normalized.contains("stop"), "Azure lost the final word")
    }
}
