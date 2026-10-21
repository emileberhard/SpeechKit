import Foundation
import os

public final class SpeechRelayTransport: Sendable, Equatable {
    enum SessionKind: Sendable {
        case realtime
        case batch
        case streaming
    }

    private let configure: @Sendable (URLSessionConfiguration) -> Void
    private let trust: ServerTrust
    private let sessions = OSAllocatedUnfairLock(initialState: [SessionKind: URLSession]())

    public init(
        configure: @escaping @Sendable (URLSessionConfiguration) -> Void,
        acceptsServerTrust: @escaping @Sendable (SecTrust) -> Bool
    ) {
        self.configure = configure
        trust = ServerTrust(accepts: acceptsServerTrust)
    }

    deinit {
        for session in sessions.withLock({ Array($0.values) }) {
            session.finishTasksAndInvalidate()
        }
    }

    public static func == (lhs: SpeechRelayTransport, rhs: SpeechRelayTransport) -> Bool {
        lhs === rhs
    }

    func session(_ kind: SessionKind, configuration: @Sendable () -> URLSessionConfiguration) -> URLSession {
        sessions.withLock { sessions in
            if let session = sessions[kind] { return session }
            let session = URLSession(configuration: prepared(configuration()), delegate: trust, delegateQueue: nil)
            sessions[kind] = session
            return session
        }
    }

    func prepared(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        let prepared = configuration.copy() as? URLSessionConfiguration ?? configuration
        configure(prepared)
        return prepared
    }

    func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.answer(challenge)
    }

    private final class ServerTrust: NSObject, URLSessionTaskDelegate, Sendable {
        private let accepts: @Sendable (SecTrust) -> Bool

        init(accepts: @escaping @Sendable (SecTrust) -> Bool) {
            self.accepts = accepts
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            answer(challenge)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge
        ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            answer(challenge)
        }

        func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return accepts(trust) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }
}
