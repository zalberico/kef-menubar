import CryptoKit
import Foundation

/// User created on, and used to sign requests to, the speaker's secure API.
///
/// The defaults are the ones KEF Connect uses when no KEF account is logged in.
/// They are the same for everyone and the speaker accepts new users without
/// authentication: this scheme authenticates clients, it is not a security
/// boundary on the local network.
public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public static let defaultUsername = "7f3c2a91-4d0b-4f65-9b3a-8e2f1c6d4a13"

    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    /// Credentials for `username` with the app's password derivation.
    public static func forUsername(_ username: String) -> Credentials {
        Credentials(username: username, password: derivePassword(username))
    }

    public static let `default` = forUsername(defaultUsername)

    /// `md5("yek_<user>_user")` as lowercase hex, like the official app.
    public static func derivePassword(_ username: String) -> String {
        Insecure.MD5.hash(data: Data("yek_\(username)_user".utf8)).hex
    }

    public var description: String { "Credentials(username: \(username), password: ***)" }

    /// Body of the unauthenticated `webserver:addUser` provisioning request.
    public var addUserPayload: JSON {
        [
            "path": "webserver:addUser",
            "role": "activate",
            "value": ["name": .string(username), "password": .string(password), "title": ""],
        ]
    }
}

/// Request signing (`Authorization: HMAC_SHA256 …`) for HTTPS POSTs.
public enum Signer {
    /// The `Authorization` header value for a request.
    ///
    /// - Parameters:
    ///   - url: full URL exactly as sent, e.g. `https://192.168.1.20:4430/api/setData`.
    ///   - body: exact request body bytes (`nil` for GET).
    ///   - nonce, timestampMs: only for deterministic tests.
    public static func authorization(
        credentials: Credentials,
        url: String,
        body: Data?,
        nonce: String? = nil,
        timestampMs: Int64? = nil
    ) -> String {
        let nonce = nonce ?? randomNonce()
        let timestamp = String(timestampMs ?? Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)))
        let nonceB64 = Data(nonce.utf8).base64EncodedString()
        let key = SymmetricKey(data: SHA256.hash(data: Data((nonce + credentials.password).utf8)))
        var message = Data("\(credentials.username).\(nonceB64).\(timestamp).\(url)".utf8)
        if let body {
            message.append(UInt8(ascii: "."))
            message.append(body)
        }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).base64EncodedString()
        let user = Data(credentials.username.utf8).base64EncodedString()
        return "HMAC_SHA256 \(user).\(nonceB64).\(timestamp).\(signature)"
    }

    /// Base64 of 6 random bytes (8 characters), like the reference client.
    static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<6).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
