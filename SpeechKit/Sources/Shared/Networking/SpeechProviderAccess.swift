import Foundation

public struct SpeechRelay: Sendable, Equatable {
    public let baseURL: URL
    public let bearerToken: String
    public let transport: SpeechRelayTransport?

    public init(baseURL: URL, bearerToken: String, transport: SpeechRelayTransport? = nil) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw SpeechKitError.invalidConfiguration(
                "Speech relay URL must be an http or https URL without credentials, query, or fragment"
            )
        }
        guard !bearerToken.isEmpty,
              bearerToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw SpeechKitError.invalidConfiguration("Speech relay bearer token is required")
        }

        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.transport = transport
    }

    func request(
        percentEncodedPath: String,
        percentEncodedQuery: String?,
        webSocket: Bool
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              percentEncodedPath.hasPrefix("/") else {
            throw SpeechKitError.invalidRequest("Could not build the speech relay URL")
        }

        if webSocket {
            components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        }

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = basePath + percentEncodedPath
        components.percentEncodedQuery = percentEncodedQuery

        guard let url = components.url else {
            throw SpeechKitError.invalidRequest("Could not build the speech relay URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension SpeechRelay {
    static let rejectionHeaderField = "X-Speech-Relay-Rejection"
    static let rejectionCloseReasonPrefix = "speech-relay-rejection:"

    func rejection(in response: HTTPURLResponse) -> SpeechKitError? {
        guard let kind = response.value(forHTTPHeaderField: Self.rejectionHeaderField), !kind.isEmpty else {
            return nil
        }
        return .relayRejected(kind: kind)
    }

    func rejection(closeReason: String?) -> SpeechKitError? {
        guard let closeReason, closeReason.hasPrefix(Self.rejectionCloseReasonPrefix) else { return nil }
        let kind = String(closeReason.dropFirst(Self.rejectionCloseReasonPrefix.count))
        return kind.isEmpty ? nil : .relayRejected(kind: kind)
    }
}

public struct LLMRouter: Sendable, Equatable {
    public let origin: URL
    public let key: String

    public init(origin: URL, key: String) throws {
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.query == nil,
              components.fragment == nil else {
            throw SpeechKitError.invalidConfiguration(
                "llm-router origin must be an http or https URL without credentials, path, query, or fragment"
            )
        }
        guard !key.isEmpty, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw SpeechKitError.invalidConfiguration("llm-router key is required")
        }

        self.origin = origin
        self.key = key
    }
}

extension LLMRouter {
    func relay(for upstream: URL) throws -> SpeechRelay {
        guard let host = upstream.host?.lowercased(),
              let path = Self.routePath(host: host, upstreamPath: upstream.path) else {
            throw SpeechKitError.invalidRequest("llm-router does not route requests for \(upstream.host ?? "this URL")")
        }
        return try relay(path: path)
    }

    func azureSpeechRelay() throws -> SpeechRelay {
        try relay(path: "/vendors/azure-speech")
    }

    private func relay(path: String) throws -> SpeechRelay {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            throw SpeechKitError.invalidRequest("Could not build the llm-router URL")
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw SpeechKitError.invalidRequest("Could not build the llm-router URL")
        }
        return try SpeechRelay(baseURL: url, bearerToken: key)
    }

    private static func routePath(host: String, upstreamPath: String) -> String? {
        switch host {
        case "api.openai.com": upstreamPath == "/v1/audio/transcriptions" ? "" : "/vendors/openai"
        case "api.elevenlabs.io": "/vendors/elevenlabs"
        case "generativelanguage.googleapis.com": "/vendors/google"
        case "api.assemblyai.com": "/vendors/assemblyai"
        case "streaming.assemblyai.com": "/vendors/assemblyai-streaming"
        default: nil
        }
    }
}

public enum SpeechProviderAccess: Sendable, Equatable {
    case router(LLMRouter)
    case relay(SpeechRelay)
}

extension SpeechProviderAccess {
    var relay: SpeechRelay? {
        guard case .relay(let relay) = self else { return nil }
        return relay
    }

    package func failure(_ response: HTTPURLResponse, body: String) -> SpeechKitError {
        relay?.rejection(in: response) ?? .httpFailure(statusCode: response.statusCode, body: body)
    }

    package func request(upstream: URL) throws -> URLRequest {
        try forwardedRequest(upstream: upstream, webSocket: false)
    }

    func webSocketRequest(upstream: URL) throws -> URLRequest {
        try forwardedRequest(upstream: upstream, webSocket: true)
    }

    func azureSpeechRelay() throws -> SpeechRelay {
        switch self {
        case .router(let router): try router.azureSpeechRelay()
        case .relay(let relay): relay
        }
    }

    private func forwardedRequest(upstream: URL, webSocket: Bool) throws -> URLRequest {
        guard let components = URLComponents(url: upstream, resolvingAgainstBaseURL: false) else {
            throw SpeechKitError.invalidRequest("Could not build the provider URL")
        }
        let target = switch self {
        case .router(let router): try router.relay(for: upstream)
        case .relay(let relay): relay
        }
        return try target.request(
            percentEncodedPath: components.percentEncodedPath,
            percentEncodedQuery: components.percentEncodedQuery,
            webSocket: webSocket
        )
    }
}
