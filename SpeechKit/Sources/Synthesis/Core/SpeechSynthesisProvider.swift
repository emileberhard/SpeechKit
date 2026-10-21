public protocol SpeechSynthesisProvider: Sendable {
    associatedtype GenerationOptions: SpeechSynthesisGenerationOptions

    var id: String { get }
    func synthesize(_ request: SpeechSynthesisRequest<GenerationOptions>) -> SpeechAudioStream
}
