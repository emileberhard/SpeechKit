import Foundation

public enum SpeechKitError: Error, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case invalidResponse
    case httpFailure(statusCode: Int, body: String)
    case providerFailure(String)
    case webSocketHandshakeFailed(statusCode: Int)
    case webSocketClosed(code: Int, reason: String?)
    case relayRejected(kind: String)
}

extension SpeechKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .invalidResponse:
            return "Invalid response from provider"
        case .httpFailure(let statusCode, let body):
            return "HTTP \(statusCode): \(body)"
        case .providerFailure(let message):
            return "Provider failure: \(message)"
        case .webSocketHandshakeFailed(let statusCode):
            return "WebSocket upgrade rejected with HTTP \(statusCode)"
        case .webSocketClosed(let code, let reason):
            if let reason, !reason.isEmpty {
                return "WebSocket closed with code \(code): \(reason)"
            }
            return "WebSocket closed with code \(code)"
        case .relayRejected(let kind):
            return "Speech relay rejected the request: \(kind)"
        }
    }
}
