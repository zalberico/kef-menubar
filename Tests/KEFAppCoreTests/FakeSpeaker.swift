import Foundation
import KEFKit

/// A small lock-protected box (this target's own; KEFKit's is internal).
final class Box<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}

/// An in-process fake speaker behind URLProtocol, separate from the KEFKit tests' stub.
/// Each fake has its own address (TEST-NET-1), so suites never see each other's requests.
final class FakeSpeaker: @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let method: String
        let endpoint: String
        /// The API path (query for reads, body for writes); `nil` for queue requests.
        let path: String?
        /// The written value, compact JSON (writes only).
        let value: String?
        /// The written typed value's payload, e.g. `40`, `false`, `"wifi"` (writes only).
        let payload: String?
    }

    let host: String
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var requests: [Request] = []
    private var inFlight = 0
    private var maxInFlight = 0
    /// Seconds before each answer, per `"METHOD path"` or path (`"*"` for every other request).
    private var delays: [String: TimeInterval] = [:]

    private static let all = Box<[String: FakeSpeaker]>([:])

    /// A fresh fake at `192.0.2.<last>` with a typical LSX II state.
    init(last: Int) {
        host = ["192", "0", "2", String(last)].joined(separator: ".")
        set(KEFPath.deviceName, string: "Test Speaker")
        set(KEFPath.modelName, string: "SP4041")
        set(KEFPath.firmware, string: "3.1.141")
        set(KEFPath.speakerStatus, typed: "kefSpeakerStatus", #""powerOn""#)
        set(KEFPath.physicalSource, source: .usb)
        set(KEFPath.volume, int: 20)
        set(KEFPath.mute, bool: false)
        set(KEFPath.maximumVolume, int: 100)
        set(KEFPath.volumeLimit, bool: false)
        set(KEFPath.playerData, raw: #"{"state":"stopped"}"#)
        Self.all.withLock { $0[host] = self }
    }

    static func speaker(at host: String?) -> FakeSpeaker? {
        guard let host else { return nil }
        return all.withLock { $0[host] }
    }

    /// A client that talks to this fake over plain HTTP (no TLS probe, no signing).
    func client(timeout: TimeInterval = 5) -> KEFClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeSpeakerProtocol.self]
        return KEFClient(transport: KEFTransport(host: host, mode: .http, timeout: timeout, configuration: config))
    }

    // MARK: State

    func set(_ path: String, raw: String) { lock.withLock { values[path] = raw } }
    func set(_ path: String, typed type: String, _ payload: String) { set(path, raw: #"{"type":"\#(type)","\#(type)":\#(payload)}"#) }
    func set(_ path: String, int: Int) { set(path, typed: "i32_", String(int)) }
    func set(_ path: String, bool: Bool) { set(path, typed: "bool_", bool ? "true" : "false") }
    func set(_ path: String, string: String) { set(path, typed: "string_", #""\#(string)""#) }
    func set(_ path: String, source: Source) { set(path, typed: "kefPhysicalSource", #""\#(source.rawValue)""#) }
    func remove(_ path: String) { _ = lock.withLock { values.removeValue(forKey: path) } }

    func delay(_ seconds: TimeInterval, for path: String = "*") { lock.withLock { delays[path] = seconds } }

    var log: [Request] { lock.withLock { requests } }
    var writes: [Request] { log.filter { $0.method == "POST" && $0.endpoint == Endpoint.setData } }
    var reads: [Request] { log.filter { $0.endpoint == Endpoint.getData } }
    /// Payloads written to `path`, in order.
    func written(_ path: String) -> [String] { writes.filter { $0.path == path }.compactMap(\.payload) }
    var highestConcurrency: Int { lock.withLock { maxInFlight } }
    func clearLog() { lock.withLock { requests = []; maxInFlight = inFlight } }

    // MARK: Serving

    /// Answer one request: (status, body, delay).
    func handle(method: String, url: URL, body: Data?) -> (Int, String, TimeInterval) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
        let endpoint = components?.path ?? url.path
        var path = query["path"]
        var written: String?
        var payload: String?
        var json: [String: Any] = [:]
        if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            json = object
            path = object["path"] as? String ?? path
            if let value = object["value"],
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                written = String(decoding: data, as: UTF8.self)
                if let typed = value as? [String: Any], let type = typed["type"] as? String, let inner = typed[type],
                   let data = try? JSONSerialization.data(withJSONObject: inner, options: [.sortedKeys, .fragmentsAllowed]) {
                    payload = String(decoding: data, as: UTF8.self)
                }
            }
        }
        return lock.withLock {
            requests.append(Request(method: method, endpoint: endpoint, path: path, value: written, payload: payload))
            let delay = path.flatMap { delays["\(method) \($0)"] ?? delays[$0] } ?? delays["*"] ?? 0
            switch endpoint {
            case Endpoint.getData:
                guard let path, let value = values[path] else { return (500, #"{"error":{"message":"no such path"}}"#, delay) }
                return (200, "[\(value)]", delay)
            case Endpoint.setData:
                if let path, let written, json["role"] as? String == "value" { values[path] = written }
                return (200, "{}", delay)
            case Endpoint.getRows:
                return (200, #"{"rows":[]}"#, delay)
            case Endpoint.modifyQueue:
                return (200, #""{q-1}""#, delay)
            case Endpoint.pollQueue:
                return (200, "[]", delays[Endpoint.pollQueue] ?? 0.2)
            default:
                return (404, "", delay)
            }
        }
    }

    fileprivate func began() { lock.withLock { inFlight += 1; maxInFlight = max(maxInFlight, inFlight) } }
    fileprivate func ended() { lock.withLock { inFlight -= 1 } }
}

/// Routes each request to the fake at its host.
final class FakeSpeakerProtocol: URLProtocol, @unchecked Sendable {
    private let state = Box<(started: Bool, finished: Bool)>((false, false))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let speaker = FakeSpeaker.speaker(at: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
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
        speaker.began()
        state.withLock { $0.started = true }
        let (status, text, delay) = speaker.handle(method: request.httpMethod ?? "GET", url: url, body: body)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard finish(speaker) else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let speaker = FakeSpeaker.speaker(at: request.url?.host) { _ = finish(speaker) }
    }

    /// Ends the request once (answered or cancelled); `false` if it already ended.
    private func finish(_ speaker: FakeSpeaker) -> Bool {
        let first = state.withLock { state -> Bool in
            guard state.started, !state.finished else { return false }
            state.finished = true
            return true
        }
        if first { speaker.ended() }
        return first
    }
}
