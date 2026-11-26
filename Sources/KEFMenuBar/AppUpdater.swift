// The GitHub (Developer ID) build only: the Mac App Store build sets APPSTORE and has no
// Sparkle, since the App Store installs its updates.
#if !APPSTORE
import AppKit
import Observation
import Sparkle

/// The app's own updates, through Sparkle. Sparkle asks on the second launch whether to check
/// automatically; a check fetches the appcast from GitHub and nothing else (no system profile).
/// Updates must carry an EdDSA signature matching `SUPublicEDKey` in Info.plist.
@MainActor @Observable
final class AppUpdater: NSObject {
    /// False while a check or an update session is under way.
    private(set) var canCheckForUpdates = false
    /// Mirrors Sparkle's setting, so SwiftUI sees changes made from Sparkle's own prompt.
    private(set) var automaticallyChecksForUpdates = false
    /// A scheduled check found this version and is waiting for the person to look at it.
    private(set) var pendingVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    /// Shows Sparkle's window: the found update, "You're up to date", or an error.
    func checkForUpdates() {
        // A menu bar app isn't active by default, and Sparkle's window should come to the front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

/// Gentle reminders: a menu bar app has no window to come back to, so a scheduled check that
/// finds an update while you're busy elsewhere leaves a note in the panel instead of an alert.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { pendingVersion = update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
    }
}
#endif
