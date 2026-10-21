import Foundation
import Testing
@testable import SpeechKit

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_TRANSCRIPTION_INTEGRATION_TESTS"] == "1"),
    .timeLimit(.minutes(2))
)
struct DictationRecordingIntegrationTests {
    private static let fixture = "clip5_realtime_dictation_en.mp3"
    private static let languageHints = ["en"]
    private static let vocabulary = ["SpeechKit", "Stockholm", "dictation"]

    @Test func wavExportTranscribesWithElevenLabsScribeV2() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 16_000, format: .wav)
        let provider = ElevenLabsTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("elevenlabs")
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "ElevenLabs Scribe v2 WAV")
    }

    @Test func wavExportTranscribesWithAzureMAITranscribe2() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 16_000, format: .wav)
        let provider = AzureSpeechTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("azure"), modelOptions: .init(transcribeStyle: .clean)
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "Azure MAI-Transcribe-2 WAV")
    }

    @Test func aacExportTranscribesWithElevenLabsScribeV2() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 16_000, format: .aac)
        let provider = ElevenLabsTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("elevenlabs")
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "ElevenLabs Scribe v2 AAC")
    }

    @Test func aacExportTranscribesWithOpenAI() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 24_000, format: .aac)
        let provider = OpenAITranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("openai"),
            model: "gpt-4o-mini-transcribe-2025-12-15"
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "OpenAI gpt-4o-mini-transcribe AAC")
    }

    @Test func aacExportTranscribesWithGemini35FlashInline() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 16_000, format: .aac)
        let provider = GeminiTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("gemini"),
            model: "gemini-3.5-flash"
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "Gemini 3.5 Flash inline AAC")
    }

    @Test func aacExportTranscribesWithGemini35Transcribe() async throws {
        let audio = try await Self.recordedAudio(sampleRate: 16_000, format: .aac)
        let provider = GeminiTranscribeProvider(configuration: try .init(
            access: IntegrationAccess.provider("gemini"),
            mode: .smart
        ))
        try await Self.assertTranscribes(audio, with: provider, name: "Gemini 3.5 Transcribe AAC")
    }

    private enum ExportFormat { case wav, aac }

    private static func recordedAudio(sampleRate: Int, format: ExportFormat) async throws -> TranscriptionAudio {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DictationRecordingIntegrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationRecordingStore<String>(
            directory: directory,
            retention: try DictationRecordingRetention(maximumCount: 5, maximumAge: .seconds(3_600))
        )
        let pcm = try FixtureAudio.pcm16(fixture, sampleRate: sampleRate)
        let writer = try await store.startRecording(owner: "integration", sampleRate: sampleRate)
        let chunkBytes = sampleRate / 10 * MemoryLayout<Int16>.size
        for offset in stride(from: 0, to: pcm.count, by: chunkBytes) {
            writer.append(pcm.subdata(in: offset..<min(offset + chunkBytes, pcm.count)))
        }
        let recording = try await writer.finish()
        #expect(recording.duration > .seconds(5))

        let wav = try await recording.transcriptionAudio(maximumByteCount: .max)
        #expect(wav.mimeType == "audio/wav")
        switch format {
        case .wav:
            return wav
        case .aac:
            let aac = try await recording.transcriptionAudio(maximumByteCount: wav.data.count - 1)
            #expect(aac.mimeType == "audio/m4a")
            #expect(aac.data.count < wav.data.count)
            return aac
        }
    }

    private static func assertTranscribes(
        _ audio: TranscriptionAudio,
        with provider: any TranscriptionProvider,
        name: String
    ) async throws {
        let result = try await TranscriptionEngine(provider: provider).transcribe(
            .init(audio: audio, languageHints: languageHints, customVocabulary: vocabulary)
        )
        let normalized = result.text.lowercased()
        let anchors = ["paste", "final", "sentence", "recording", "stop"].filter { normalized.contains($0) }.count
        #expect(anchors >= 4, "\(name) matched \(anchors) of 5 fixture anchor words")
        #expect(normalized.contains("stop"), "\(name) lost the final word")
    }
}
