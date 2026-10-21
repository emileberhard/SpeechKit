public struct SpeechSynthesisEngine<Provider: SpeechSynthesisProvider>: Sendable {
    private let provider: Provider

    public init(provider: Provider) {
        self.provider = provider
    }

    public func synthesize(
        _ request: SpeechSynthesisRequest<Provider.GenerationOptions>
    ) -> SpeechAudioStream {
        provider.synthesize(request)
    }
}
