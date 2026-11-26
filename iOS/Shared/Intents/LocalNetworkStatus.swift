import dnssd
import Foundation
import Network
import os

/// Whether Local Network access is turned off for the app (its extension shares the
/// app's permission), to explain a speaker that couldn't be reached. Asked only after a
/// failure, so it never slows down a command that worked.
enum LocalNetworkStatus {
    /// How long to wait for the system to say why a connection can't be made.
    static let wait: Duration = .milliseconds(1500)

    /// `true` when the system reports the local network as denied: on the general path,
    /// or on a connection to `host` (port 80, closed straight away, nothing is sent).
    static func isDenied(host: String?) async -> Bool {
        if await generalPathIsDenied() { return true }
        guard let host, !host.isEmpty else { return false }
        return await connectionIsDenied(to: host)
    }

    private static func generalPathIsDenied() async -> Bool {
        let monitor = NWPathMonitor()
        let denied = await first(timeout: wait, cancel: { monitor.cancel() }) { finish in
            monitor.pathUpdateHandler = { path in
                finish(path.status != .satisfied && path.unsatisfiedReason == .localNetworkDenied)
            }
            monitor.start(queue: DispatchQueue(label: "LocalNetworkStatus.path"))
        }
        return denied ?? false
    }

    private static func connectionIsDenied(to host: String) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 80, using: .tcp)
        let denied = await first(timeout: wait, cancel: { connection.cancel() }) { finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    let reason = connection.currentPath?.unsatisfiedReason
                    finish(reason == .localNetworkDenied || isPolicyDenied(error))
                case .ready:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "LocalNetworkStatus.connection"))
        }
        return denied ?? false
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    /// The first value `start` reports, or `nil` after `timeout`; `cancel` runs either way.
    private static func first(
        timeout: Duration, cancel: @escaping @Sendable () -> Void,
        start: (@escaping @Sendable (Bool) -> Void) -> Void
    ) async -> Bool? {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let value: Bool? = await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            start { finish($0) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
        cancel()
        return value
    }
}
