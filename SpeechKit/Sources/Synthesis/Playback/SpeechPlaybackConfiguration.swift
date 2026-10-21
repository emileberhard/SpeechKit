import Foundation

public struct SpeechPlaybackConfiguration: Sendable, Equatable {
    public enum Buffering: Sendable, Equatable {
        /// Starts early only when measured delivery is fast enough to sustain playback.
        /// Slower streams are buffered to completion so network cadence never becomes audible.
        case automatic

        /// Starts after the requested amount of audio is buffered, regardless of delivery rate.
        case streaming(minimumBufferedDuration: Duration)

        /// Buffers the complete response before playback.
        case complete
    }

    public enum AudioSession: Sendable, Equatable {
        case managed(
            usage: Usage,
            output: Output,
            deactivatesAfterPlayback: Bool
        )
        case externallyManaged
    }

    public enum Usage: Sendable, Equatable {
        case spokenAudio
        case voiceChat
    }

    public enum Output: Sendable, Equatable {
        case systemDefault
        case builtInSpeakerWhenAvailable
    }

    public let buffering: Buffering
    public let audioSession: AudioSession

    public init(
        buffering: Buffering = .automatic,
        audioSession: AudioSession = .managed(
            usage: .spokenAudio,
            output: .systemDefault,
            deactivatesAfterPlayback: true
        )
    ) {
        self.buffering = buffering
        self.audioSession = audioSession
    }

    public static let spokenAudio = SpeechPlaybackConfiguration()

    public static let voiceChat = SpeechPlaybackConfiguration(
        audioSession: .managed(
            usage: .voiceChat,
            output: .builtInSpeakerWhenAvailable,
            deactivatesAfterPlayback: false
        )
    )

    public static let externallyManaged = SpeechPlaybackConfiguration(
        audioSession: .externallyManaged
    )
}
