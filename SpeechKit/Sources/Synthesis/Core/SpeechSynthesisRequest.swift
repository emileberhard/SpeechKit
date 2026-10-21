import Foundation

public protocol SpeechSynthesisGenerationOptions: Sendable {}

public struct DefaultSpeechSynthesisOptions: SpeechSynthesisGenerationOptions {
    public init() {}
}

public struct SpeechSynthesisRequest<GenerationOptions: SpeechSynthesisGenerationOptions>: Sendable {
    public let text: String
    public let options: GenerationOptions

    public init(text: String, options: GenerationOptions) {
        self.text = text
        self.options = options
    }
}

public extension SpeechSynthesisRequest where GenerationOptions == DefaultSpeechSynthesisOptions {
    init(text: String) {
        self.init(text: text, options: DefaultSpeechSynthesisOptions())
    }
}

public struct SpeechAudioFormat: Sendable, Equatable {
    public enum SampleFormat: Sendable, Equatable {
        case signedInteger16LittleEndian
    }

    public let sampleFormat: SampleFormat
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleFormat: SampleFormat, sampleRate: Double, channelCount: Int) {
        self.sampleFormat = sampleFormat
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public static let pcm16Mono24kHz = SpeechAudioFormat(
        sampleFormat: .signedInteger16LittleEndian,
        sampleRate: 24_000,
        channelCount: 1
    )
}

public struct SpeechAudioChunk: Sendable, Equatable {
    public let data: Data
    public let format: SpeechAudioFormat

    public init(data: Data, format: SpeechAudioFormat) {
        self.data = data
        self.format = format
    }
}

public typealias SpeechAudioStream = AsyncThrowingStream<SpeechAudioChunk, Error>
