import Foundation

#if os(iOS)
import AVFAudio
#endif

actor SpeechAudioSessionController {
    private static let activationRetryDelays: [Duration] = [
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    private var activePlaybackID: UUID?

    func begin(
        playbackID: UUID,
        configuration: SpeechPlaybackConfiguration.AudioSession
    ) async throws {
        activePlaybackID = playbackID

        #if os(iOS)
        guard case .managed(let usage, let output, _) = configuration else { return }
        let session = AVAudioSession.sharedInstance()

        do {
            try configure(session, usage: usage, output: output)
            try await activate(session, playbackID: playbackID)
            guard activePlaybackID == playbackID else { throw CancellationError() }
            try routeToSpeakerIfNeeded(session, usage: usage, output: output)
        } catch {
            if activePlaybackID == playbackID {
                activePlaybackID = nil
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
            throw error
        }
        #endif
    }

    func end(
        playbackID: UUID,
        configuration: SpeechPlaybackConfiguration.AudioSession
    ) {
        guard activePlaybackID == playbackID else { return }
        activePlaybackID = nil

        #if os(iOS)
        guard case .managed(_, _, let deactivatesAfterPlayback) = configuration,
              deactivatesAfterPlayback else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        #endif
    }
}

#if os(iOS)
private extension SpeechAudioSessionController {
    func configure(
        _ session: AVAudioSession,
        usage: SpeechPlaybackConfiguration.Usage,
        output: SpeechPlaybackConfiguration.Output
    ) throws {
        switch usage {
        case .spokenAudio:
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
        case .voiceChat:
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
            if output == .builtInSpeakerWhenAvailable {
                options.insert(.defaultToSpeaker)
            }
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        }
    }

    func activate(_ session: AVAudioSession, playbackID: UUID) async throws {
        var latestError: Error?

        for attempt in 0...Self.activationRetryDelays.count {
            try Task.checkCancellation()
            guard activePlaybackID == playbackID else { throw CancellationError() }
            if attempt > 0 {
                try await Task.sleep(for: Self.activationRetryDelays[attempt - 1])
            }

            do {
                try session.setActive(true)
                return
            } catch {
                latestError = error
            }
        }

        throw latestError ?? SpeechKitError.invalidConfiguration(
            "Unable to activate the audio session"
        )
    }

    func routeToSpeakerIfNeeded(
        _ session: AVAudioSession,
        usage: SpeechPlaybackConfiguration.Usage,
        output: SpeechPlaybackConfiguration.Output
    ) throws {
        guard usage == .voiceChat,
              output == .builtInSpeakerWhenAvailable,
              session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver })
        else { return }

        try session.overrideOutputAudioPort(.speaker)
    }
}
#endif
