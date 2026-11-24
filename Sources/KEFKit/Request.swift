import Foundation

public enum KEFError: Error, Sendable, Equatable, LocalizedError {
    /// Speaker unreachable (timeout, refused, TLS failure...).
    case connection(String)
    /// The speaker rejected our credentials even after re-provisioning.
    case auth(String)
    /// HTTP error status with the speaker's message.
    case api(status: Int, message: String, path: String?)
    /// Unexpected answer.
    case invalidResponse(String)
    /// The path is on the safety block list (see ``KEFSafety``).
    case blocked(String)
    /// A value was refused before sending (out of range, not finite...).
    case invalidValue(String)

    public var isConnection: Bool { if case .connection = self { true } else { false } }

    public var errorDescription: String? {
        switch self {
        case .connection(let message): "Speaker unreachable: \(message)"
        case .auth(let message): "Authentication failed: \(message)"
        case .api(let status, let message, let path): "\(path ?? "Request") failed (HTTP \(status)): \(message)"
        case .invalidResponse(let message): "Unexpected answer: \(message)"
        case .blocked(let path): "Refusing to touch \(path)"
        case .invalidValue(let message): "Invalid value: \(message)"
        }
    }
}

/// An HTTP request to the speaker (sans I/O).
public struct KEFRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var endpoint: String
    public var query: [(String, String)] = []
    public var body: Data?
    public var timeout: TimeInterval?
    /// API path concerned, for error messages.
    public var path: String?

    /// Endpoint plus query string, encoded like Python's `urlencode`.
    public var target: String {
        query.isEmpty ? endpoint : endpoint + "?" + Self.formEncode(query)
    }

    public static func getData(_ path: String, roles: String = "value") -> KEFRequest {
        KEFRequest(method: .get, endpoint: Endpoint.getData, query: [("path", path), ("roles", roles)], path: path)
    }

    public static func setData(_ path: String, _ value: JSON, role: String = "value") -> KEFRequest {
        let body: JSON = ["path": .string(path), "role": .string(role), "value": value]
        return KEFRequest(method: .post, endpoint: Endpoint.setData, body: body.compactData, path: path)
    }

    public static func getRows(_ path: String, from: Int = 0, to: Int = 19, roles: String = "@all") -> KEFRequest {
        KEFRequest(
            method: .get, endpoint: Endpoint.getRows,
            query: [("path", path), ("roles", roles), ("from", String(from)), ("to", String(to))],
            path: path)
    }

    public static func modifyQueue(subscribe: [String], unsubscribe: [String] = [], queueID: String?) -> KEFRequest {
        func subscriptions(_ paths: [String]) -> JSON {
            .array(paths.map { ["path": .string($0), "type": "itemWithValue"] })
        }
        var payload = JSONObject()
        if let queueID { payload["queueId"] = .string(queueID) }
        payload["subscribe"] = subscriptions(subscribe)
        payload["unsubscribe"] = subscriptions(unsubscribe)
        return KEFRequest(method: .post, endpoint: Endpoint.modifyQueue, body: JSON.object(payload).compactData)
    }

    /// Long-poll the queue for up to `timeout` seconds (the HTTP timeout adds a margin).
    public static func pollQueue(_ queueID: String, timeout: Int = 25) -> KEFRequest {
        KEFRequest(
            method: .get, endpoint: Endpoint.pollQueue,
            query: [("queueId", queueID), ("timeout", String(timeout))],
            timeout: TimeInterval(timeout) + 15)
    }

    static func formEncode(_ items: [(String, String)]) -> String {
        items.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
    }

    /// Python's `urllib.parse.quote_plus`: unreserved characters kept, space → `+`.
    static func quotePlus(_ string: String) -> String {
        var out = ""
        for byte in string.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "_"), UInt8(ascii: "."),
                 UInt8(ascii: "-"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x20:
                out += "+"
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// Human message of an error answer: `{"error":{"name":…,"message":…}}` or plain text.
func errorMessage(_ body: Data) -> String {
    if let json = try? JSON(parsing: body), let error = json["error"], let message = error["message"]?.string {
        if let name = error["name"]?.string { return "\(message) (\(name))" }
        return message
    }
    let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(text.prefix(500))
}
