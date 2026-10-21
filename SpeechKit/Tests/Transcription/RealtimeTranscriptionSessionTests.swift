import Foundation
import Testing
@testable import SpeechKit

@Suite(.timeLimit(.minutes(1)))
struct RealtimeTranscriptionSessionTests {
    private let finalized: [RealtimeTranscriptionEvent] = [.committedTranscript("hi"), .finalizationCompleted]

    @Test func elevenLabsFinalizesOnTheTimestampedCommitWhenTimestampsAreRequested() {
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(
            from: .committedTranscript("hi"), includesTimestamps: true
        ) == [.committedTranscript("hi")])
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(
            from: .committedTranscriptWithTimestamps(text: "hi", languageCode: "en", words: []), includesTimestamps: true
        ) == [.finalizationCompleted])
    }

    @Test func elevenLabsFinalizesOnThePlainCommitWithoutTimestamps() {
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(
            from: .committedTranscript("hi"), includesTimestamps: false
        ) == finalized)
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(
            from: .partialTranscript("h"), includesTimestamps: false
        ).isEmpty)
    }

    @Test func elevenLabsFinalizesAnEmptyCommit() {
        #expect(ElevenLabsRealtimeSession.transcriptionEvents(
            from: .committedTranscript(""), includesTimestamps: false
        ) == [.committedTranscript(""), .finalizationCompleted])
    }

    @Test func geminiFinalizesEachActivity() {
        #expect(GeminiRealtimeSession.transcriptionEvents(from: .committedTranscript("hi")) == finalized)
        #expect(GeminiRealtimeSession.transcriptionEvents(from: .partialTranscript("h")).isEmpty)
    }

    @Test func assemblyAIFinalizesOnlyOnTerminationAndKeepsEveryTurnBeforeIt() {
        let turnsThenTermination: [AssemblyAIRealtimeEvent] = [
            .committedTranscript(turnOrder: 0, text: "ended before the stop"),
            .partialTranscript(turnOrder: 1, text: "fl"),
            .committedTranscript(turnOrder: 1, text: "flushed by the commit"),
            .sessionTerminated(.init(audioDurationSeconds: 4, sessionDurationSeconds: 5)),
        ]

        #expect(turnsThenTermination.flatMap(AssemblyAIRealtimeSession.transcriptionEvents(from:)) == [
            .committedTranscript("ended before the stop"),
            .committedTranscript("flushed by the commit"),
            .finalizationCompleted,
        ])
    }

    @Test func assemblyAIPauseBeforeTheStopStillFinalizesThroughTermination() {
        let events: [AssemblyAIRealtimeEvent] = [
            .committedTranscript(turnOrder: 0, text: "everything said"),
            .sessionTerminated(.init(audioDurationSeconds: 4, sessionDurationSeconds: 5)),
        ]

        #expect(events.flatMap(AssemblyAIRealtimeSession.transcriptionEvents(from:)) == [
            .committedTranscript("everything said"),
            .finalizationCompleted,
        ])
    }

    @Test func openAIFinalizesOnlyTheExplicitCommitInItemOrder() throws {
        var commits = OpenAIRealtimeCommits()
        let received = try [
            OpenAIRealtimeEvent.speechStarted(itemID: "a"),
            .speechStopped(itemID: "a"),
            .audioCommitted(itemID: "a"),
            .speechStarted(itemID: "b"),
            .audioCommitted(itemID: "b"),
        ].flatMap { try commits.receive($0) }
        #expect(received.isEmpty)

        #expect(try commits.receive(.committedTranscript(itemID: "b", transcript: "second")).isEmpty)
        #expect(try commits.receive(.committedTranscript(itemID: "a", transcript: "first")) == [
            .committedTranscript("first"),
            .committedTranscript("second"),
            .finalizationCompleted,
        ])
    }

    @Test func openAIWaitsForEveryItemPendingAtTheStop() throws {
        var commits = OpenAIRealtimeCommits()
        for event in [OpenAIRealtimeEvent.speechStopped(itemID: "a"), .audioCommitted(itemID: "a"), .audioCommitted(itemID: "b")] {
            _ = try commits.receive(event)
        }

        #expect(try commits.receive(.committedTranscript(itemID: "a", transcript: "first")) == [.committedTranscript("first")])
        #expect(try commits.receive(.committedTranscript(itemID: "b", transcript: "")) == [
            .committedTranscript(""),
            .finalizationCompleted,
        ])
    }

    @Test func openAIVoiceActivityCommitsNeverFinalize() throws {
        var commits = OpenAIRealtimeCommits()
        _ = try commits.receive(.speechStopped(itemID: "a"))
        _ = try commits.receive(.audioCommitted(itemID: "a"))

        #expect(try commits.receive(.committedTranscript(itemID: "a", transcript: "vad")) == [.committedTranscript("vad")])
    }

    @Test func openAIEmptyCommitAfterVoiceActivityFinalizesOnceEarlierItemsComplete() throws {
        var commits = OpenAIRealtimeCommits()
        for event in [OpenAIRealtimeEvent.speechStarted(itemID: "a"), .speechStopped(itemID: "a"), .audioCommitted(itemID: "a")] {
            _ = try commits.receive(event)
        }

        #expect(try commits.receive(.commitRejected(message: "empty")).isEmpty)
        #expect(try commits.receive(.committedTranscript(itemID: "a", transcript: "all of it")) == [
            .committedTranscript("all of it"),
            .finalizationCompleted,
        ])
    }

    @Test func openAIRejectedCommitDuringSpeechFails() throws {
        var commits = OpenAIRealtimeCommits()
        _ = try commits.receive(.speechStarted(itemID: "a"))

        #expect(throws: OpenAIRealtimeSessionError.self) { try commits.receive(.commitRejected(message: "rejected")) }
    }

    @Test func openAIWithoutTurnDetectionFinalizesEachCommit() throws {
        var commits = OpenAIRealtimeCommits()
        #expect(try commits.receive(.audioCommitted(itemID: "a")).isEmpty)
        #expect(try commits.receive(.committedTranscript(itemID: "a", transcript: "hi")) == finalized)
    }

    @Test func relaysMappedEventsThenTheProviderFailure() async throws {
        let (source, continuation) = AsyncThrowingStream<GeminiRealtimeEvent, Error>.makeStream()
        continuation.yield(.setupComplete)
        continuation.yield(.committedTranscript("hi"))
        continuation.finish(throwing: GeminiRealtimeSessionError.notConnected)

        var received: [RealtimeTranscriptionEvent] = []
        do {
            for try await event in source.realtimeTranscriptionEvents(GeminiRealtimeSession.transcriptionEvents(from:)) {
                received.append(event)
            }
            Issue.record("Expected the provider failure")
        } catch is GeminiRealtimeSessionError {}
        #expect(received == finalized)
    }

    @Test func abandoningTheEventsReleasesTheProviderStream() async throws {
        let (source, continuation) = AsyncThrowingStream<GeminiRealtimeEvent, Error>.makeStream()
        let (terminated, terminationSignal) = AsyncStream<Void>.makeStream()
        continuation.onTermination = { _ in terminationSignal.finish() }
        continuation.yield(.committedTranscript("hi"))

        for try await _ in source.realtimeTranscriptionEvents(GeminiRealtimeSession.transcriptionEvents(from:)) {
            break
        }

        for await _ in terminated {}
    }

    @Test func progressiveEmptyRecordingFailsTheEventStream() async throws {
        let session = ProgressiveRealtimeTranscriptionSession(provider: UnansweredProgressiveProvider(), request: .init())
        let events = try await session.connectTranscription()
        try await session.requestCommit()

        await #expect(throws: SpeechKitError.self) {
            for try await _ in events {}
        }
        await session.disconnect()
    }

    @Test func progressiveDisconnectEndsAPendingFinalizationWithoutAnError() async throws {
        let session = ProgressiveRealtimeTranscriptionSession(provider: UnansweredProgressiveProvider(), request: .init())
        let events = try await session.connectTranscription()
        try await session.sendAudioChunk(Data([0, 0]))
        try await session.requestCommit()

        await session.disconnect()

        var received: [RealtimeTranscriptionEvent] = []
        for try await event in events {
            received.append(event)
        }
        #expect(received.isEmpty)
        await #expect(throws: CancellationError.self) { try await session.sendAudioChunk(Data([0, 0])) }
    }

    @Test func progressiveSessionConnectsOnlyOnce() async throws {
        let session = ProgressiveRealtimeTranscriptionSession(provider: UnansweredProgressiveProvider(), request: .init())
        _ = try await session.connectTranscription()

        await #expect(throws: ProgressiveTranscriptionError.alreadyFinished) { try await session.connectTranscription() }
        await session.disconnect()
        await #expect(throws: CancellationError.self) { try await session.connectTranscription() }
    }

    @Test func transcriptJoinsSpokenCommitsAndSkipsSoundEvents() {
        var transcript = RealtimeTranscript()
        #expect(transcript.text == nil)

        let accepted = [" hello ", "   ", "[laughter] [music]", "world. [applause]"].map { transcript.append($0) }

        #expect(accepted == [true, false, false, true])
        #expect(transcript.text == "hello world. [applause]")
    }
}

private struct UnansweredProgressiveProvider: ProgressiveTranscriptionProvider {
    let id = "unanswered"
    let progressiveSampleRate = 16_000
    let maximumAudioByteCount = 1_000_000

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        throw SpeechKitError.invalidRequest("Batch transcription is outside this test")
    }

    func startProgressiveTranscription(
        _ request: ProgressiveTranscriptionRequest
    ) async throws -> ProgressiveTranscriptionSession {
        try .unansweredTestSession()
    }
}
