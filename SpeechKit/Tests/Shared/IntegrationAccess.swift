import CryptoKit
import Foundation
import Network
import Testing
@testable import SpeechKit

enum IntegrationAccess {
    static func provider(_ relayProvider: String) throws -> SpeechProviderAccess {
        if let relay = try relay(relayProvider) {
            return .relay(relay)
        }
        return .router(try router())
    }

    static func relay(_ provider: String) throws -> SpeechRelay? {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["SPEECHKIT_RELAY_URL"], !base.isEmpty else {
            return nil
        }
        guard let url = URL(string: base),
              let token = environment["SPEECHKIT_RELAY_TOKEN"], !token.isEmpty else {
            throw SpeechKitError.invalidConfiguration("SPEECHKIT_RELAY_URL requires a URL and SPEECHKIT_RELAY_TOKEN")
        }
        return try SpeechRelay(baseURL: url.appending(path: provider), bearerToken: token, transport: transport(environment))
    }

    private static func transport(_ environment: [String: String]) throws -> SpeechRelayTransport? {
        guard let pin = environment["SPEECHKIT_RELAY_CERT_SHA256"], !pin.isEmpty else { return nil }
        let proxy = try environment["SPEECHKIT_RELAY_PROXY"].map { try proxyConfiguration($0, environment: environment) }
        return SpeechRelayTransport(
            configure: { configuration in
                if let proxy { configuration.proxyConfigurations = [proxy] }
            },
            acceptsServerTrust: { leafMatches($0, pin: pin) }
        )
    }

    private static func proxyConfiguration(_ address: String, environment: [String: String]) throws -> ProxyConfiguration {
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]),
              let user = environment["SPEECHKIT_RELAY_PROXY_USER"],
              let password = environment["SPEECHKIT_RELAY_PROXY_PASSWORD"],
              let pin = environment["SPEECHKIT_RELAY_PROXY_CERT_SHA256"] else {
            throw SpeechKitError.invalidConfiguration(
                "SPEECHKIT_RELAY_PROXY needs host:port, SPEECHKIT_RELAY_PROXY_USER, _PASSWORD and _CERT_SHA256"
            )
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(leafMatches(sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, DispatchQueue(label: "SpeechKitTests.relayProxyTrust"))
        var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: NWEndpoint.Host(String(parts[0])), port: NWEndpoint.Port(integerLiteral: port)),
            tlsOptions: tls
        )
        proxy.applyCredential(username: user, password: password)
        return proxy
    }

    private static func leafMatches(_ trust: SecTrust, pin: String) -> Bool {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return false }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        return digest.map { String(format: "%02x", $0) }.joined() == pin.lowercased()
    }

    private static func router() throws -> LLMRouter {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["SPEECHKIT_ROUTER_URL"],
              let url = URL(string: origin),
              let key = environment["SPEECHKIT_ROUTER_KEY"], !key.isEmpty else {
            try Test.cancel("Set SPEECHKIT_ROUTER_URL and SPEECHKIT_ROUTER_KEY or configure a relay")
        }
        return try LLMRouter(origin: url, key: key)
    }
}
