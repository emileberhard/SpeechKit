import Foundation

public struct TranscriptionEngine: Sendable {
    private let provider: any TranscriptionProvider

    public var maximumAudioByteCount: Int { provider.maximumAudioByteCount }

    public init(provider: any TranscriptionProvider) {
        self.provider = provider
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await provider.transcribe(request)
    }
}
