import Foundation

public nonisolated enum VoiceFilterError: Error, Equatable {
    case voicesUnavailable
    case profileUnreadable
    case deadlineExceeded
    case modelMissing

}
