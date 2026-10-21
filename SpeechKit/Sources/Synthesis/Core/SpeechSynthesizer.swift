import Foundation

public actor SpeechSynthesizer<Provider: SpeechSynthesisProvider> {
    private let engine: SpeechSynthesisEngine<Provider>
    private let player: StreamingSpeechPlayer
    private let audioSessionController = SpeechAudioSessionController()

    public init(
        provider: Provider,
        player: StreamingSpeechPlayer = StreamingSpeechPlayer()
    ) {
        self.engine = SpeechSynthesisEngine(provider: provider)
        self.player = player
    }

    public func speak(
        _ request: SpeechSynthesisRequest<Provider.GenerationOptions>,
        playback: SpeechPlaybackConfiguration = .spokenAudio,
        onPlaybackStarted: (@Sendable () async -> Void)? = nil,
        onPlaybackVisualizationChanged: (@Sendable (SpeechPlaybackVisualization) async -> Void)? = nil
    ) async throws {
        let playbackID = UUID()
        defer {
            await audioSessionController.end(
                playbackID: playbackID,
                configuration: playback.audioSession
            )
        }

        try await player.play(
            engine.synthesize(request),
            buffering: playback.buffering,
            prepareForPlayback: {
                try await self.audioSessionController.begin(
                    playbackID: playbackID,
                    configuration: playback.audioSession
                )
            },
            onPlaybackStarted: onPlaybackStarted,
            onPlaybackVisualizationChanged: onPlaybackVisualizationChanged
        )
    }

    public func stop() async {
        await player.stop()
    }
}
