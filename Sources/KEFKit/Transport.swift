import Foundation
import os

public enum TransportMode: String, Sendable, CaseIterable {
    /// Probe HTTPS on port 4430 (recent firmware), fall back to HTTP on port 80.
    case auto
    case https
    case http
}

/// Sends requests to one speaker over HTTPS (port 4430) or HTTP (port 80).
///
/// In `auto` mode the first request probes HTTPS and falls back to HTTP. Once
/// HTTPS has worked the transport never falls back (a speaker does not
/// downgrade); while on HTTP, HTTPS is re-probed every five minutes. HTTPS POSTs
/// are signed, after provisioning our user with an unauthenticated
/// `webserver:addUser`. One URLSession keeps connections alive: the speaker does
/// not cope well with many fresh TLS handshakes in a row.
public actor KEFTransport {
    public nonisolated let host: String
    public nonisolated let mode: TransportMode
    public nonisolated let credentials: Credentials
    public nonisolated let httpsBase: String
    public nonisolated let httpBase: String
    /// The URLSession used for every request (also handy to fetch artwork from the speaker).
    public nonisolated let session: URLSession

    static let probeTimeout: TimeInterval = 3
    /// The speaker delays its 401 to an unknown user by ~10 s: signed requests wait longer.
    static let signedTimeout: TimeInterval = 15
    static let reprobeInterval: Duration = .seconds(300)
    static let jsonContentType = "application/json; charset=utf-8"
    static let probePath = KEFPath.deviceName

    private let defaultTimeout: TimeInterval
    private var base: String?
    private var chosenAt = ContinuousClock.now
    private var httpsConfirmed = false
    private var provisioned = false
    private var connectTask: Task<Void, Error>?
    private var provisionTask: Task<Void, Error>?
    private var closed = false
    public private(set) var isSecure: Bool?

    private let log = Logger(subsystem: "KEFKit", category: "transport")

    public init(
        host: String,
        mode: TransportMode = .auto,
        credentials: Credentials = .default,
        timeout: TimeInterval = 10,
        httpPort: Int = 80,
        httpsPort: Int = 4430,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.host = host
        self.mode = mode
        self.credentials = credentials
        self.defaultTimeout = timeout
        let urlHost = host.contains(":") && !host.hasPrefix("[")
            ? "[" + host.replacingOccurrences(of: "%", with: "%25") + "]" : host
        httpsBase = "https://\(urlHost):\(httpsPort)"
        httpBase = httpPort == 80 ? "http://\(urlHost)" : "http://\(urlHost):\(httpPort)"

        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: KEFSessionDelegate(speakerHost: host), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Close for good: later requests fail.
    public func close() {
        closed = true
        base = nil
        session.invalidateAndCancel()
    }

    /// GET `url` with this transport's session (artwork the speaker serves), failing instead of
    /// crashing once the transport is closed.
    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await load(URLRequest(url: url))
    }

    /// Run `request` on the session. A task on an invalidated URLSession raises an Objective-C
    /// exception (an app crash Swift can't catch), and `close()` may run whenever this actor
    /// is free. `URLSession.data(for:)` is no help: it leaves the actor before it creates its
    /// task. So the `closed` check and the task's creation happen here, in one synchronous
    /// stretch on this actor, where `close()` can't come in between.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let pending = PendingTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                guard !closed else {
                    continuation.resume(throwing: KEFError.connection("client closed"))
                    return
                }
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                pending.started(task)
                task.resume()
            }
        } onCancel: {
            pending.cancel()
        }
    }

    /// Forget the scheme chosen in `auto` mode: the next request probes again.
    public func invalidate() {
        if mode == .auto { base = nil }
    }

    // MARK: Scheme selection

    private var needsConnect: Bool {
        guard let base else { return true }
        return mode == .auto && base == httpBase && ContinuousClock.now - chosenAt > Self.reprobeInterval
    }

    private func use(_ newBase: String) {
        base = newBase
        isSecure = newBase == httpsBase
        chosenAt = .now
    }

    /// Choose the scheme (probing HTTPS in `auto` mode) if not done yet.
    public func connect() async throws {
        guard !closed else { throw KEFError.connection("client closed") }
        guard needsConnect else { return }
        if let connectTask { return try await connectTask.value }
        let task = Task { try await self.performConnect() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func performConnect() async throws {
        switch mode {
        case .http: use(httpBase)
        case .https: use(httpsBase)
        case .auto:
            if httpsConfirmed { use(httpsBase); return }
            do {
                _ = try await send(base: httpsBase, .getData(Self.probePath), timeout: Self.probeTimeout, authorization: nil)
                log.debug("\(self.host, privacy: .public): using HTTPS")
                httpsConfirmed = true
                use(httpsBase)
            } catch let error as KEFError where error.isConnection {
                log.debug("\(self.host, privacy: .public): HTTPS unavailable (\(error.localizedDescription, privacy: .public)), using HTTP")
                use(httpBase)
            }
        }
    }

    // MARK: Requests

    /// Send `request` and return the decoded JSON answer (`nil` for an empty body).
    public func request(_ request: KEFRequest) async throws -> JSON? {
        try await connect()
        guard let base else { throw KEFError.connection("\(host): not connected") }
        let sign = base == httpsBase && request.method == .post
        var timeout = request.timeout ?? defaultTimeout
        if sign { timeout = max(timeout, Self.signedTimeout) }

        var status = 0
        var data = Data()
        do {
            var authorization: String?
            if sign {
                try await provision(force: false)
                authorization = self.authorization(for: request)
            }
            (status, data) = try await send(base: base, request, timeout: timeout, authorization: authorization)
            if status == 401 && sign {
                log.debug("\(self.host, privacy: .public): 401, re-provisioning and retrying")
                try await provision(force: true)
                (status, data) = try await send(base: base, request, timeout: timeout, authorization: self.authorization(for: request))
                if status == 401 {
                    throw KEFError.auth("\(host) rejected our credentials (\(request.path ?? request.endpoint))")
                }
            }
        } catch let error as KEFError where error.isConnection {
            if sign { provisioned = false }  // the speaker may have forgotten our user
            invalidate()
            throw error
        }
        guard status < 400 else {
            throw KEFError.api(status: status, message: errorMessage(data), path: request.path)
        }
        if base == httpsBase { httpsConfirmed = true }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return nil }
        do {
            return try JSON(parsing: data)
        } catch {
            throw KEFError.invalidResponse("invalid JSON from speaker: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    func authorization(for request: KEFRequest) -> String {
        Signer.authorization(credentials: credentials, url: httpsBase + request.target, body: request.body)
    }

    /// Create our user on the speaker (unauthenticated `webserver:addUser`).
    private func provision(force: Bool) async throws {
        if provisioned && !force { return }
        if let provisionTask { return try await provisionTask.value }
        let task = Task {
            let request = KEFRequest(
                method: .post, endpoint: Endpoint.setData,
                body: credentials.addUserPayload.compactData, path: "webserver:addUser")
            let (status, body) = try await send(base: httpsBase, request, timeout: Self.signedTimeout, authorization: nil)
            // Don't retry on every request if it failed: a 401 triggers a new attempt.
            provisioned = true
            let alreadyExists = body.range(of: Data("already exists".utf8)) != nil
            if !(200..<300).contains(status) && !alreadyExists {
                log.warning("\(self.host, privacy: .public): could not create user (HTTP \(status)): \(errorMessage(body), privacy: .public)")
            }
        }
        provisionTask = task
        defer { provisionTask = nil }
        try await task.value
    }

    private func send(
        base: String, _ request: KEFRequest, timeout: TimeInterval, authorization: String?
    ) async throws -> (Int, Data) {
        // close() may have run while this request was suspended (in connect or provision);
        // load() refuses then, without touching the invalidated session.
        guard let url = URL(string: base + request.target) else {
            throw KEFError.invalidResponse("invalid URL \(base + request.target)")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue(Self.jsonContentType, forHTTPHeaderField: "Content-Type")
        }
        if let authorization { urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await load(urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw KEFError.invalidResponse("not an HTTP response")
            }
            return (http.statusCode, data)
        } catch let error as URLError {
            if error.code == .cancelled && Task.isCancelled { throw CancellationError() }
            throw KEFError.connection("\(host): \(error.localizedDescription)")
        }
    }
}

/// The URLSession task of one ``KEFTransport`` request, for a cancellation that can come
/// before or after it exists.
private final class PendingTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func started(_ task: URLSessionTask) {
        let cancelNow = lock.withLock {
            if !cancelled { self.task = task }
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}
