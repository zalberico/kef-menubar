import Foundation
import Security

/// Trust evaluation for the speaker's HTTPS API (port 4430).
///
/// Recent firmware serves a certificate issued by a private KEF root CA (embedded
/// in the official app, and below). Like the app, only that CA is trusted, and
/// when connecting to an IP address the address must be in the certificate's
/// subjectAltName. Speaker certificates only carry IP addresses, so for a host
/// *name* only the chain is verified.
public enum KEFTrust {
    /// KEF private root CA (`C=HK, O=KEF, CN=KEF-CA`, valid 2025-04-16 → 2045-04-11,
    /// SHA-256 E5:F2:CE:C7:92:26:CC:3E:3C:88:24:38:74:7B:4F:BD:AE:89:33:86:BD:40:DA:7F:1C:13:FC:7D:7C:B1:E4:5B).
    static let rootCABase64 = """
        MIIDiTCCAnGgAwIBAgIUPdcMVcifwg5uyfe947k0f9j84wswDQYJKoZIhvcNAQEL\
        BQAwVDELMAkGA1UEBhMCSEsxEjAQBgNVBAgMCUhvbmcgS29uZzESMBAGA1UEBwwJ\
        SG9uZyBLb25nMQwwCgYDVQQKDANLRUYxDzANBgNVBAMMBktFRi1DQTAeFw0yNTA0\
        MTYxMTIxMjRaFw00NTA0MTExMTIxMjRaMFQxCzAJBgNVBAYTAkhLMRIwEAYDVQQI\
        DAlIb25nIEtvbmcxEjAQBgNVBAcMCUhvbmcgS29uZzEMMAoGA1UECgwDS0VGMQ8w\
        DQYDVQQDDAZLRUYtQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCv\
        W6BZZo6/yXIKnW/MjfH98poFgqeU1LD2OuSotMJ7wK6Zs3gvrQwNxBhjLYyxnY8x\
        TkWndjn2ZO9f4MNs+KfJKQAGs9bnBmOyR86iPIoGKQeVlbxvMqijR107Qm6/Nc5q\
        NuzpwvVQP4Y8fHSLlLckUjwPQXJVDp8jXzC42Ksc1QdFXU5RB3WW4ZJ2/An6dlEQ\
        X63e1YbroXf8PNCsJCtL8cTM4L4tOVGX7fkSbd1evIT5ov6Y64NW2Vfn8GoLMxtN\
        voFI03SqnZtyQFse1e/qz4zEPg4st8R4mHLvAElVRgIXFoRr8GgghlpKs2dwgGPQ\
        yaQp5GxyDxhE7OmCJeuhAgMBAAGjUzBRMB0GA1UdDgQWBBR04vp9Ece9c2/Ozmhc\
        PtBNFZR7AjAfBgNVHSMEGDAWgBR04vp9Ece9c2/OzmhcPtBNFZR7AjAPBgNVHRMB\
        Af8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQAl//C1SiRnENWzAY5tr2GxS9pS\
        lf4HeizrJQ5jKB/8Vmk1dxJJsX0OGHAgOJC73mHppi2nxOkwf5q5sYZwPVMXD4os\
        L0D4qzIB175CyGMaW2GqUkevlUdjjjA9CGZEinRrL1Qic97nGVUA8icqHmJVV2Dp\
        syjh2wkNhoInk8acLeWzPGTNhoywLFNTXdPaxzjHFgqYFcf4p72QLb7u+3l17OS1\
        gjd3nDle9sS+8jXgaPudOZg16DbgXUMF6R1oI+Gi2VueBjEz2zq598uSTX4VbEuN\
        Ej0PUhU5xbB2eTeE+jqBlizhVwkeKyFAm5/7tXA3PH9xLY1rM7kJb7phrvir
        """

    public static let rootCA: SecCertificate = {
        guard let der = Data(base64Encoded: rootCABase64),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { fatalError("Embedded KEF root CA is invalid") }
        return certificate
    }()

    /// Whether `trust` chains to the KEF root CA (and, for an IP `host`, lists it in the SAN).
    public static func evaluate(_ trust: SecTrust, host: String) -> Bool {
        let name: CFString? = isIPAddress(host) ? host.trimmingCharacters(in: ["[", "]"]) as CFString : nil
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, name))
        SecTrustSetAnchorCertificates(trust, [rootCA] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    public static func isIPAddress(_ host: String) -> Bool {
        var host = host.trimmingCharacters(in: ["[", "]"])
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// URLSession delegate: KEF CA trust for the speaker, default handling for anything else,
/// and no redirects (like the reference client's `allow_redirects=False`).
final class KEFSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }

    let speakerHost: String

    init(speakerHost: String) {
        self.speakerHost = speakerHost.trimmingCharacters(in: ["[", "]"]).lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        // Artwork may come from internet services: only the speaker gets the KEF CA.
        guard space.host.lowercased() == speakerHost else { return (.performDefaultHandling, nil) }
        if KEFTrust.evaluate(trust, host: space.host) {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
