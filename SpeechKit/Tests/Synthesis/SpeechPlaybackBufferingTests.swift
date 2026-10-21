import Foundation
import Testing
@testable import SpeechKit

@Suite("Speech playback buffering")
struct SpeechPlaybackBufferingTests {
    @Test("Automatic buffering waits when delivery is slower than playback")
    func automaticBufferingWaitsForSlowStream() {
        let shouldStart = SpeechStreamBufferingDecision.shouldStart(
            buffering: .automatic,
            streamFinished: false,
            receivedAudioDuration: 0.4,
            queuedAudioDuration: 0.4,
            deliveryDuration: 1.08,
            underrunCount: 0
        )

        #expect(!shouldStart)
    }

    @Test("Automatic buffering starts a sustainable stream after probing")
    func automaticBufferingStartsSustainableStream() {
        let shouldStart = SpeechStreamBufferingDecision.shouldStart(
            buffering: .automatic,
            streamFinished: false,
            receivedAudioDuration: 0.4,
            queuedAudioDuration: 0.4,
            deliveryDuration: 0.3,
            underrunCount: 0
        )

        #expect(shouldStart)
    }

    @Test("A completed stream always starts")
    func completedStreamStarts() {
        let shouldStart = SpeechStreamBufferingDecision.shouldStart(
            buffering: .complete,
            streamFinished: true,
            receivedAudioDuration: 0.04,
            queuedAudioDuration: 0.04,
            deliveryDuration: 1,
            underrunCount: 0
        )

        #expect(shouldStart)
    }

    @Test("Explicit streaming honors its minimum buffer")
    func explicitStreamingHonorsMinimumBuffer() {
        #expect(
            !SpeechStreamBufferingDecision.shouldStart(
                buffering: .streaming(minimumBufferedDuration: .seconds(1)),
                streamFinished: false,
                receivedAudioDuration: 0.8,
                queuedAudioDuration: 0.8,
                deliveryDuration: 0.2,
                underrunCount: 0
            )
        )
        #expect(
            SpeechStreamBufferingDecision.shouldStart(
                buffering: .streaming(minimumBufferedDuration: .seconds(1)),
                streamFinished: false,
                receivedAudioDuration: 1,
                queuedAudioDuration: 1,
                deliveryDuration: 0.3,
                underrunCount: 0
            )
        )
    }

    @Test("Voice chat keeps its audio session active")
    func voiceChatPlaybackConfiguration() {
        guard case .managed(
            usage: .voiceChat,
            output: .builtInSpeakerWhenAvailable,
            deactivatesAfterPlayback: false
        ) = SpeechPlaybackConfiguration.voiceChat.audioSession else {
            Issue.record("Expected the voice-chat audio session preset")
            return
        }
    }
}
