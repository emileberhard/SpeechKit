import AVFoundation
import Foundation
import Testing
@testable import SpeechKit

@Suite("Realtime dictation integration", .serialized)
struct RealtimeTranscriptionIntegrationTests {
    private let fixture = RealtimeFixture(
        fileName: "clip5_realtime_dictation_en.mp3",
        anchorGroups: [
            ["paste"],
            ["final"],
            ["sentence"],
            ["recording"],
            ["stops", "stop", "stopped"],
        ],
        minimumAnchorMatches: 3,
        requiredTailAnchorGroup: ["stops", "stop", "stopped"],
        streamStartSeconds: 6.55,
        streamEndSeconds: 9.55
    )
    private let realtimeVocabulary = ["SpeechKit", "Stockholm", "dictation"]

    @Test(arguments: [AssemblyAIRealtimeMode.balanced, .maximumAccuracy])
    func assemblyAIUniversal35ProPreservesTheAbruptEnding(mode: AssemblyAIRealtimeMode) async throws {
        try requireIntegrationEnabled()
        let configuration = try AssemblyAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("assemblyai"),
            keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(from: realtimeVocabulary),
            languageHints: ["en"],
            mode: mode
        )

        try await assertTranscribesFixture(
            AssemblyAIRealtimeSession(configuration: configuration),
            providerName: "AssemblyAI universal-3-5-pro (\(mode.rawValue))"
        )
    }

    @Test func openAIRealtimeWhisperPreservesTheAbruptEnding() async throws {
        try requireIntegrationEnabled()
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("openai"),
            modelID: "gpt-realtime-whisper",
            customVocabulary: realtimeVocabulary,
            languageHints: ["en"],
            transcriptionDelay: .high,
            noiseReduction: .nearField
        )

        try await assertTranscribesFixture(
            OpenAIRealtimeSession(configuration: configuration),
            providerName: "OpenAI gpt-realtime-whisper"
        )
    }

    @Test func openAIGPT4oTranscribeWithSemanticVADPreservesTheAbruptEnding() async throws {
        try requireIntegrationEnabled()
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("openai"),
            modelID: "gpt-4o-transcribe",
            customVocabulary: realtimeVocabulary + [String(repeating: "x", count: 51)] + (0..<101).map { "Term\($0)" },
            languageHints: ["en", "sv"],
            turnDetection: .semanticVAD(eagerness: .low),
            noiseReduction: .nearField
        )

        try await assertTranscribesFixture(
            OpenAIRealtimeSession(configuration: configuration),
            providerName: "OpenAI gpt-4o-transcribe (semantic VAD)"
        )
    }

    @Test func assemblyAIFinalizesAfterAPauseBeforeTheStop() async throws {
        try requireIntegrationEnabled()
        let configuration = try AssemblyAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("assemblyai"),
            keyterms: AssemblyAIRealtimeSessionConfiguration.compatibleKeyterms(from: realtimeVocabulary),
            languageHints: ["en"]
        )

        try await assertTranscribesFixture(
            AssemblyAIRealtimeSession(configuration: configuration),
            thenSilence: .seconds(3),
            providerName: "AssemblyAI universal-3-5-pro after a pause"
        )
    }

    @Test func openAIGPT4oTranscribeWithSemanticVADFinalizesAfterAPauseBeforeTheStop() async throws {
        try requireIntegrationEnabled()
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("openai"),
            modelID: "gpt-4o-transcribe",
            customVocabulary: realtimeVocabulary,
            languageHints: ["en"],
            turnDetection: .semanticVAD(eagerness: .low),
            noiseReduction: .nearField
        )

        try await assertTranscribesFixture(
            OpenAIRealtimeSession(configuration: configuration),
            thenSilence: .seconds(10),
            providerName: "OpenAI gpt-4o-transcribe (semantic VAD) after a pause"
        )
    }

    @Test func openAIRealtimeWhisperFinalizesAMinuteOfBufferedAudio() async throws {
        try requireIntegrationEnabled()
        let configuration = try OpenAIRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("openai"),
            modelID: "gpt-realtime-whisper",
            languageHints: ["en"],
            transcriptionDelay: .high,
            noiseReduction: .nearField
        )

        try await assertFinalizesBufferedMinute(
            OpenAIRealtimeSession(configuration: configuration),
            providerName: "OpenAI gpt-realtime-whisper"
        )
    }

    @Test func gemini35TranscribeLiveFinalizesAMinuteOfBufferedAudio() async throws {
        try requireIntegrationEnabled()
        let configuration = try GeminiRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("gemini"),
            languageHints: ["en"],
            mode: .smart
        )

        try await assertFinalizesBufferedMinute(
            GeminiRealtimeSession(configuration: configuration),
            providerName: "Gemini 3.5 Transcribe Live"
        )
    }

    @Test func elevenLabsScribeV2RealtimeFinalizesADictationShorterThanTwoSeconds() async throws {
        try requireIntegrationEnabled()
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("elevenlabs"),
            languageHints: ["sv", "en"],
            includeTimestamps: false
        )
        let session = ElevenLabsRealtimeSession(configuration: configuration)
        let pcm = try fixturePCM(sampleRate: session.sampleRate, from: fixture.streamEndSeconds - 1.5, to: fixture.streamEndSeconds)

        let transcript = try await dictate(pcm, through: session, pacing: .milliseconds(100), providerName: "ElevenLabs scribe_v2_realtime 1.5 s")

        #expect(!transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(arguments: [true, false])
    func elevenLabsScribeV2RealtimePreservesTheAbruptEnding(includeTimestamps: Bool) async throws {
        try requireIntegrationEnabled()
        let configuration = try ElevenLabsRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("elevenlabs"),
            keyterms: ElevenLabsRealtimeSessionConfiguration.compatibleKeyterms(from: realtimeVocabulary),
            languageHints: ["sv", "en"],
            includeTimestamps: includeTimestamps
        )

        try await assertTranscribesFixture(
            ElevenLabsRealtimeSession(configuration: configuration),
            providerName: "ElevenLabs scribe_v2_realtime (timestamps: \(includeTimestamps))"
        )
    }

    @Test func gemini35TranscribeLivePreservesTheAbruptEnding() async throws {
        try requireIntegrationEnabled()
        let configuration = try GeminiRealtimeSessionConfiguration(
            access: IntegrationAccess.provider("gemini"),
            customVocabulary: realtimeVocabulary,
            languageHints: ["en"],
            mode: .smart
        )

        try await assertTranscribesFixture(
            GeminiRealtimeSession(configuration: configuration),
            providerName: "Gemini 3.5 Transcribe Live"
        )
    }

    @Test func azureMAI2ProgressivePreservesTheAbruptEnding() async throws {
        try requireIntegrationEnabled()
        let provider = AzureSpeechTranscriptionProvider(configuration: try .init(
            access: IntegrationAccess.provider("azure"), modelOptions: .init(transcribeStyle: .clean)
        ))
        let session = ProgressiveRealtimeTranscriptionSession(
            provider: provider,
            request: .init(languageHints: ["en"], customVocabulary: realtimeVocabulary)
        )

        try await assertTranscribesFixture(session, providerName: "Azure MAI-Transcribe-2 progressive")
    }

    private func assertTranscribesFixture(
        _ session: any RealtimeTranscriptionSession,
        providerName: String
    ) async throws {
        try await assertTranscribesFixture(session, thenSilence: .zero, providerName: providerName)
    }

    private func assertTranscribesFixture(
        _ session: any RealtimeTranscriptionSession,
        thenSilence silence: Duration,
        providerName: String
    ) async throws {
        var pcm = try fixturePCM(sampleRate: session.sampleRate, from: fixture.streamStartSeconds, to: fixture.streamEndSeconds)
        pcm.append(Data(count: Int(silence.components.seconds) * session.sampleRate * MemoryLayout<Int16>.size))
        let transcript = try await dictate(pcm, through: session, pacing: .milliseconds(100), providerName: providerName)
        assertTranscript(transcript, providerName: providerName)
    }

    private func assertFinalizesBufferedMinute(
        _ session: any RealtimeTranscriptionSession,
        providerName: String
    ) async throws {
        let clip = try fixturePCM(sampleRate: session.sampleRate, from: 0, to: .infinity)
        let bytesPerMinute = 60 * session.sampleRate * MemoryLayout<Int16>.size
        let pcm = Data(repeatElement(clip, count: bytesPerMinute / clip.count + 1).joined().prefix(bytesPerMinute))

        let transcript = try await dictate(pcm, through: session, pacing: .zero, providerName: "\(providerName) 60 s unpaced")

        let score = anchorScore(actualText: transcript, anchorGroups: fixture.anchorGroups)
        #expect(score.matches >= fixture.minimumAnchorMatches, "\(providerName) weak long transcript: \(transcript)")
    }

    private func dictate(
        _ pcm: Data,
        through session: any RealtimeTranscriptionSession,
        pacing: Duration,
        providerName: String
    ) async throws -> String {
        let dictation = RealtimeDictation(session: session)
        let chunkSize = session.sampleRate / 10 * MemoryLayout<Int16>.size
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            dictation.append(pcm.subdata(in: offset..<end))
            offset = end
            if pacing > .zero, offset < pcm.count {
                try await Task.sleep(for: pacing)
            }
        }
        let stoppedAt = ContinuousClock.now
        let transcript = try await dictation.finish()
        let audioDuration = Duration.seconds(pcm.count / MemoryLayout<Int16>.size) / session.sampleRate
        print("\(providerName): finalized \(ContinuousClock.now - stoppedAt) after the stop, audio \(audioDuration)")
        return transcript
    }

    private func fixturePCM(sampleRate: Int, from startSeconds: TimeInterval, to endSeconds: TimeInterval) throws -> Data {
        let fixtureURL = try fixtureAudioURL(fileName: fixture.fileName)
        let fullPCMData = try Self.loadPCM16MonoData(from: fixtureURL, sampleRate: Double(sampleRate))
        let bytesPerSecond = Double(sampleRate * MemoryLayout<Int16>.size)
        let startOffset = min(fullPCMData.count, Int(startSeconds * bytesPerSecond) & ~1)
        let endOffset = endSeconds.isFinite ? min(fullPCMData.count, Int(endSeconds * bytesPerSecond) & ~1) : fullPCMData.count
        guard startOffset < endOffset else {
            throw RealtimeIntegrationError.emptyPCMData
        }
        return fullPCMData.subdata(in: startOffset..<endOffset)
    }

    private func assertTranscript(_ transcript: String, providerName: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty, "\(providerName) returned empty realtime transcript")

        let score = anchorScore(actualText: trimmed, anchorGroups: fixture.anchorGroups)
        #expect(
            score.matches >= fixture.minimumAnchorMatches,
            "\(providerName) weak realtime transcript. Matched \(score.matches)/\(score.totalAnchors) anchor groups. Transcript: \(trimmed)"
        )
        let tailScore = anchorScore(actualText: trimmed, anchorGroups: [fixture.requiredTailAnchorGroup])
        #expect(
            tailScore.matches == 1,
            "\(providerName) lost the abrupt fixture ending. Transcript: \(trimmed)"
        )
    }

    private func fixtureAudioURL(fileName: String, filePath: String = #filePath) throws -> URL {
        let testsDirectory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let fixtureURL = testsDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("Audio")
            .appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RealtimeIntegrationError.missingFixture(fileName)
        }

        return fixtureURL
    }

    private static func loadPCM16MonoData(from url: URL, sampleRate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard (5...10).contains(durationSeconds) else {
            throw RealtimeIntegrationError.invalidFixtureDuration(durationSeconds)
        }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw RealtimeIntegrationError.unavailableAudioBuffer
        }
        try file.read(into: inputBuffer)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw RealtimeIntegrationError.unavailableOutputFormat
        }

        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw RealtimeIntegrationError.unavailableConverter
        }

        let sampleRateRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = max(1, Int((Double(inputBuffer.frameLength) * sampleRateRatio).rounded(.up)))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(outputFrameCapacity)
        ) else {
            throw RealtimeIntegrationError.unavailableAudioBuffer
        }

        let inputState = AudioConversionInputState(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputState.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            inputState.didProvideInput = true
            outStatus.pointee = .haveData
            return inputState.buffer
        }

        if let conversionError {
            throw RealtimeIntegrationError.conversionFailed(conversionError.localizedDescription)
        }
        guard status != .error else {
            throw RealtimeIntegrationError.conversionFailed("AVAudioConverter returned .error")
        }

        let byteCount = Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        guard byteCount > 0, let dataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw RealtimeIntegrationError.emptyPCMData
        }

        return Data(bytes: dataPointer, count: byteCount)
    }

    private func anchorScore(actualText: String, anchorGroups: [[String]]) -> (matches: Int, totalAnchors: Int) {
        let transcriptTokens = normalizedTokens(actualText)
        let matches = anchorGroups.filter { group in
            !Set(group.flatMap { normalizedTokens($0) }).isDisjoint(with: transcriptTokens)
        }.count

        return (matches, anchorGroups.count)
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

private struct RealtimeFixture {
    let fileName: String
    let anchorGroups: [[String]]
    let minimumAnchorMatches: Int
    let requiredTailAnchorGroup: [String]
    let streamStartSeconds: TimeInterval
    let streamEndSeconds: TimeInterval
}

private final class AudioConversionInputState: @unchecked Sendable {
    nonisolated(unsafe) let buffer: AVAudioPCMBuffer
    nonisolated(unsafe) var didProvideInput = false

    nonisolated init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private enum RealtimeIntegrationError: Error, LocalizedError {
    case missingFixture(String)
    case invalidFixtureDuration(TimeInterval)
    case unavailableAudioBuffer
    case unavailableOutputFormat
    case unavailableConverter
    case conversionFailed(String)
    case emptyPCMData

    var errorDescription: String? {
        switch self {
        case .missingFixture(let fileName):
            return "Missing realtime integration fixture: \(fileName)"
        case .invalidFixtureDuration(let duration):
            return "Realtime integration fixture must be 5-10 seconds, got \(duration) seconds"
        case .unavailableAudioBuffer:
            return "Unable to allocate realtime integration audio buffer"
        case .unavailableOutputFormat:
            return "Unable to create realtime integration PCM output format"
        case .unavailableConverter:
            return "Unable to create realtime integration audio converter"
        case .conversionFailed(let message):
            return "Realtime integration audio conversion failed: \(message)"
        case .emptyPCMData:
            return "Realtime integration fixture converted to empty PCM data"
        }
    }
}
