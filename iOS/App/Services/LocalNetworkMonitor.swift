import dnssd
import Foundation
import Network
import Observation

/// Notices when Local Network access is turned off for the app: a Bonjour browser for the
/// speaker's service waits with `PolicyDenied` then. iOS reports that while its permission
/// prompt is still up too, so ``isDenied`` only turns on once the app is active again and
/// the denial has lasted a couple of seconds: the explanation never flashes under the
/// system alert.
@MainActor @Observable
final class LocalNetworkMonitor {
    /// Show the "Allow Local Network" state.
    private(set) var isDenied = false

    /// Called when access comes back after a denial (the connection should retry at once).
    @ObservationIgnored var onAllowed: (() -> Void)?

    static let confirmDelay: Duration = .seconds(2)

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var reportedDenied = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var confirmTask: Task<Void, Never>?

    /// Browse while the speaker can't be reached (one browser at most).
    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_kef-info._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The app's scene phase: only an active app shows the denial.
    func setActive(_ active: Bool) {
        isActive = active
        reevaluate()
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            setReportedDenied(Self.isPolicyDenied(error))
        case .ready:
            setReportedDenied(false)
        default:
            break
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    private func setReportedDenied(_ denied: Bool) {
        let wasDenied = reportedDenied
        reportedDenied = denied
        if wasDenied, !denied {
            isDenied = false
            onAllowed?()
        }
        reevaluate()
    }

    private func reevaluate() {
        confirmTask?.cancel()
        confirmTask = nil
        guard reportedDenied else {
            isDenied = false
            return
        }
        guard isActive, !isDenied else { return }
        confirmTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmDelay)
            guard !Task.isCancelled, let self, self.reportedDenied, self.isActive else { return }
            self.isDenied = true
        }
    }
}
