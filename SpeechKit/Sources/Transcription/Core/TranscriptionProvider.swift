import Foundation

public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var maximumAudioByteCount: Int { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}
