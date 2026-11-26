#if DEBUG || PROBE
import Foundation
import KEFAppCore
import KEFKit
import Network
import os

/// Reads the speaker once, the way a widget, control or intent would, and logs how it went.
/// Read-only: it never writes to the speaker. Debug builds only.
enum SpeakerProbe {
    /// Runs the probe and returns the line it appended to ``ProbeLog``.
    @discardableResult
    static func run(timeout: Duration = .seconds(5)) async -> String {
        let started = ContinuousClock.now
        let config = AppGroup.speakerConfig()
        var outcome: String
        do {
            let command = try SpeakerCommand.connect(config, timeout: timeout)
            do {
                let snapshot = try await command.snapshot()
                outcome = "ok \(snapshot.isOn ? "on" : "standby") vol=\(snapshot.volume)"
            } catch {
                outcome = "error \(describe(error))"
            }
            await command.close()
        } catch {
            outcome = "error \(describe(error))"
        }
        let elapsed = started.duration(to: .now).components
        let ms = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
        let path = await currentPath()
        let line = [
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .current).format(.now),
            Bundle.main.bundleIdentifier ?? "?",
            "mode=\(config.hostMode.rawValue)",
            outcome,
            "path=\(path)",
            "\(ms)ms",
        ].joined(separator: " ")
        ProbeLog.append(line)
        return line
    }

    /// The error's kind and code only: messages can carry an address, so they are never logged.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SpeakerCommandError:
            switch error {
            case .noSpeaker: return "noSpeaker"
            case .differentSpeaker: return "differentSpeaker"
            case .unreachable: return "unreachable"
            case .timedOut(let writeSent): return "timedOut(writeSent: \(writeSent))"
            case .unsupportedInput: return "unsupportedInput"
            case .controlUnavailable: return "controlUnavailable"
            case .failed: return "failed"
            }
        case let error as KEFError:
            switch error {
            case .connection: return "KEFError.connection"
            case .auth: return "KEFError.auth"
            case .api(let status, _, _): return "KEFError.api(\(status))"
            case .invalidResponse: return "KEFError.invalidResponse"
            case .blocked: return "KEFError.blocked"
            case .invalidValue: return "KEFError.invalidValue"
            }
        case let error as URLError:
            return "URLError(\(error.code.rawValue))"
        case let error as NWError:
            switch error {
            case .posix(let code): return "NWError.posix(\(code.rawValue))"
            case .dns(let code): return "NWError.dns(\(code))"
            case .tls(let status): return "NWError.tls(\(status))"
            default: return "NWError"
            }
        case is CancellationError:
            return "cancelled"
        default:
            let error = error as NSError
            return "\(error.domain)(\(error.code))"
        }
    }

    /// The network path's status and, when unsatisfied, why (for example `localNetworkDenied`).
    static func currentPath() async -> String {
        let monitor = NWPathMonitor()
        let path: NWPath = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: path) }
            }
            monitor.start(queue: DispatchQueue(label: "SpeakerProbe.path"))
        }
        monitor.cancel()
        switch path.status {
        case .satisfied: return "satisfied"
        case .requiresConnection: return "requiresConnection"
        case .unsatisfied: return "unsatisfied(\(reason(path.unsatisfiedReason)))"
        @unknown default: return "unknown"
        }
    }

    private static func reason(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "notAvailable"
        case .cellularDenied: "cellularDenied"
        case .wifiDenied: "wifiDenied"
        case .localNetworkDenied: "localNetworkDenied"
        case .vpnInactive: "vpnInactive"
        @unknown default: "other"
        }
    }
}
#endif
