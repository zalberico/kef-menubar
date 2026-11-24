import Foundation
import Testing
@testable import KEFKit

/// In-process fake speaker behind URLProtocol.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let url: String
        let body: Data?
        let authorization: String?
    }

    typealias Handler = @Sendable (Seen) throws -> (Int, String)

    static let state = Locked<(handler: Handler?, seen: [Seen])>((nil, []))

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = (handler, []) }
    }

    static var seen: [Seen] { state.withLock { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let seen = Seen(method: request.httpMethod ?? "GET", url: request.url!.absoluteString, body: body,
                        authorization: request.value(forHTTPHeaderField: "Authorization"))
        let handler = Self.state.withLock { state -> Handler? in
            state.seen.append(seen)
            return state.handler
        }
        do {
            let (status, text) = try handler!(seen)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct TransportTests {
    static let host = "192.168.1.78"
    static let https = "https://192.168.1.78:4430"

    func makeClient(_ mode: TransportMode = .auto) -> KEFClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return KEFClient(transport: KEFTransport(host: Self.host, mode: mode, configuration: config))
    }

    static func isAddUser(_ seen: StubProtocol.Seen) -> Bool {
        seen.body.map { String(decoding: $0, as: UTF8.self).contains("webserver:addUser") } ?? false
    }

    /// Recompute the signature from the header's own nonce and timestamp.
    static func verify(_ seen: StubProtocol.Seen) -> Bool {
        guard let header = seen.authorization, header.hasPrefix("HMAC_SHA256 ") else { return false }
        let parts = header.dropFirst("HMAC_SHA256 ".count).split(separator: ".").map(String.init)
        guard parts.count == 4, let nonceData = Data(base64Encoded: parts[1]),
              let ts = Int64(parts[2]) else { return false }
        let expected = Signer.authorization(
            credentials: .default, url: seen.url, body: seen.body,
            nonce: String(decoding: nonceData, as: UTF8.self), timestampMs: ts)
        return expected == header
    }

    @Test func autoProbesHTTPSProvisionsOnceAndSigns() async throws {
        StubProtocol.install { seen in
            if seen.method == "GET" { return (200, #"[{"type":"i32_","i32_":37}]"#) }
            return (200, Self.isAddUser(seen) ? "" : "{}")
        }
        let client = makeClient()
        #expect(try await client.volume() == 37)
        try await client.setVolume(38)
        try await client.setMuted(true)

        let seen = StubProtocol.seen
        #expect(seen.map(\.method) == ["GET", "GET", "POST", "POST", "POST"])
        #expect(seen.allSatisfy { $0.url.hasPrefix(Self.https) })
        #expect(seen[0].url.contains("settings%3A%2FdeviceName"))  // probe
        #expect(Self.isAddUser(seen[2]) && seen[2].authorization == nil)
        #expect(seen.filter(Self.isAddUser).count == 1)
        #expect(seen.filter { $0.method == "GET" }.allSatisfy { $0.authorization == nil })
        for post in seen[3...] {
            #expect(post.url == Self.https + "/api/setData")
            #expect(Self.verify(post))
        }
        #expect(String(decoding: seen[3].body!, as: UTF8.self) == #"{"path":"player:volume","role":"value","value":{"type":"i32_","i32_":38}}"#)
        #expect(await client.transport.isSecure == true)
    }

    @Test func unauthorizedTriggersReprovisionAndRetry() async throws {
        let rejected = Locked(false)
        StubProtocol.install { seen in
            if seen.method == "GET" { return (200, "[]") }
            if Self.isAddUser(seen) { return (500, #"{"error":{"message":"User already exists"}}"#) }
            let first = rejected.withLock { done -> Bool in defer { done = true }; return !done }
            return first ? (401, "") : (200, "{}")
        }
        let client = makeClient()
        try await client.setSource(.usb)
        let seen = StubProtocol.seen
        #expect(seen.filter(Self.isAddUser).count == 2)
        let writes = seen.filter { $0.method == "POST" && !Self.isAddUser($0) }
        #expect(writes.count == 2)
        #expect(writes.allSatisfy(Self.verify))
        #expect(writes[0].authorization != writes[1].authorization)  // fresh nonce
    }

    @Test func persistentUnauthorizedIsAnAuthError() async throws {
        StubProtocol.install { seen in
            if seen.method == "GET" { return (200, "[]") }
            return Self.isAddUser(seen) ? (200, "") : (401, "")
        }
        await #expect(throws: KEFError.self) { try await makeClient().setMuted(false) }
        #expect(StubProtocol.seen.filter(Self.isAddUser).count == 2)
    }

    @Test func fallsBackToPlainHTTPWithoutSigning() async throws {
        StubProtocol.install { seen in
            if seen.url.hasPrefix("https") { throw URLError(.cannotConnectToHost) }
            return seen.method == "GET" ? (200, #"[{"type":"bool_","bool_":true}]"#) : (200, "")
        }
        let client = makeClient()
        #expect(try await client.isMuted() == true)
        try await client.setMuted(false)
        let seen = StubProtocol.seen
        #expect(seen.count == 3)
        #expect(seen[1].url.hasPrefix("http://192.168.1.78/api/getData"))
        #expect(seen[2].url == "http://192.168.1.78/api/setData")
        #expect(seen[2].authorization == nil)
        #expect(!seen.contains(where: Self.isAddUser))
        #expect(await client.transport.isSecure == false)
    }

    @Test func connectionErrorsInvalidateTheScheme() async throws {
        let down = Locked(true)
        StubProtocol.install { seen in
            if down.withLock({ $0 }) { throw URLError(.timedOut) }
            return (200, #"[{"type":"i32_","i32_":5}]"#)
        }
        let client = makeClient(.https)
        await #expect(throws: KEFError.self) { try await client.volume() }
        down.withLock { $0 = false }
        #expect(try await client.volume() == 5)
    }

    @Test func apiErrorsCarryTheSpeakerMessage() async throws {
        StubProtocol.install { _ in
            (500, #"{"error":{"name":"CMAbstractWorker::invalidPath","message":"Node at path 'x' does not exist"}}"#)
        }
        do {
            _ = try await makeClient(.https).getData("x")
            Issue.record("expected an error")
        } catch let KEFError.api(status, message, path) {
            #expect(status == 500)
            #expect(message.contains("does not exist"))
            #expect(path == "x")
        }
    }

    @Test func eventQueueSubscribesPollsAndForgetsExpiredQueues() async throws {
        let polls = Locked(0)
        StubProtocol.install { seen in
            if Self.isAddUser(seen) { return (200, "") }
            if seen.url.contains("modifyQueue") { return (200, #""{q-1}""#) }
            let count = polls.withLock { n -> Int in n += 1; return n }
            if count == 1 { return (200, #"[{"path":"player:volume","itemType":"update","itemValue":{"type":"i32_","i32_":9}}]"#) }
            return (400, "Unknown queue id!")
        }
        let queue = makeClient(.https).makeEventQueue()
        #expect(try await queue.subscribe([KEFPath.volume, KEFPath.mute]))
        #expect(await queue.queueID == "{q-1}")
        let events = try await queue.poll()
        #expect(events.map(\.value) == [.int(9)])
        #expect(StubProtocol.seen.last!.url.contains("queueId=%7Bq-1%7D&timeout=25"))
        await #expect(throws: KEFError.self) { try await queue.poll() }
        #expect(await queue.queueID == nil)
    }
    // MARK: Firmware

    static let firmwareIdle = #"[{"type":"firmwareUpdateStatus","firmwareUpdateStatus":{"state":"idle","downloadProgress":0}}]"#
    static let firmwareAvailable = #"[{"type":"firmwareUpdateStatus","firmwareUpdateStatus":{"state":"newUpdateAvailable","downloadProgress":0,"imageDescription":{"version":"3.2.10.0x1234567","forcedUpdate":false}}}]"#

    @Test func firmwareCheckSendsTheSignedCheckAction() async throws {
        StubProtocol.install { seen in
            if Self.isAddUser(seen) { return (200, "") }
            return seen.method == "GET" ? (200, #"[{"type":"string_","string_":"LSX II"}]"#) : (200, "{}")
        }
        try await makeClient(.https).checkForFirmwareUpdate()
        let post = try #require(StubProtocol.seen.last)
        #expect(post.method == "POST")
        #expect(String(decoding: post.body!, as: UTF8.self) == #"{"path":"firmwareupdate:checkForUpdate","role":"activate","value":{}}"#)
        #expect(Self.verify(post))
    }

    @Test func firmwareInstallIsRefusedWithoutAnAvailableUpdate() async throws {
        StubProtocol.install { seen in
            if Self.isAddUser(seen) { return (200, "") }
            return seen.method == "GET" ? (200, Self.firmwareIdle) : (200, "{}")
        }
        await #expect(throws: KEFError.self) { try await makeClient(.https).installFirmwareUpdate() }
        #expect(!StubProtocol.seen.contains { $0.body.map { String(decoding: $0, as: UTF8.self).contains("downloadNewUpdate") } ?? false })
    }

    @Test func firmwareInstallSendsDownloadNewUpdateWhenAvailable() async throws {
        StubProtocol.install { seen in
            if Self.isAddUser(seen) { return (200, "") }
            return seen.method == "GET" ? (200, Self.firmwareAvailable) : (200, "{}")
        }
        try await makeClient(.https).installFirmwareUpdate()
        let posts = StubProtocol.seen.filter { $0.method == "POST" && !Self.isAddUser($0) }
        #expect(posts.count == 1)
        #expect(String(decoding: posts[0].body!, as: UTF8.self) == #"{"path":"firmwareupdate:downloadNewUpdate","role":"activate","value":{}}"#)
        #expect(Self.verify(posts[0]))
    }
}
