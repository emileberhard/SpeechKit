import Foundation

package enum SpeechKitURLSessionFactory {
    private static let realtime = URLSession(configuration: configuration(for: .realtime))
    private static let batch = URLSession(configuration: configuration(for: .batch))
    private static let streaming = URLSession(configuration: configuration(for: .streaming))

    static func realtimeSession(for access: SpeechProviderAccess) -> URLSession {
        session(.realtime, for: access)
    }

    package static func batchSession(for access: SpeechProviderAccess) -> URLSession {
        session(.batch, for: access)
    }

    static func streamingSession(for access: SpeechProviderAccess) -> URLSession {
        session(.streaming, for: access)
    }

    private static func session(_ kind: SpeechRelayTransport.SessionKind, for access: SpeechProviderAccess) -> URLSession {
        if let transport = access.relay?.transport {
            return transport.session(kind) { configuration(for: kind) }
        }
        switch kind {
        case .realtime: return realtime
        case .batch: return batch
        case .streaming: return streaming
        }
    }

    private static func configuration(for kind: SpeechRelayTransport.SessionKind) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        switch kind {
        case .realtime:
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60
        case .batch:
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 10 * 60
        case .streaming:
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 10 * 60
        }
        return configuration
    }
}
