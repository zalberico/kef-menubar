import KEFAppCore
import SwiftUI
import UIKit

/// Follows the app's scene phase: a few seconds after the app goes to the background the
/// speaker connection is suspended (inside a background task, so pending writes still go
/// out); coming back cancels a pending suspend or resumes. `.inactive` (Control Center,
/// the app switcher, a system prompt, folding) changes nothing.
@MainActor
final class Lifecycle {
    /// How long the app stays connected in the background (app-switcher flicks never reconnect).
    static let suspendDelay: Duration = .seconds(5)

    private let model: SpeakerModel
    private var pendingSuspend: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Bumped by every schedule and every return to the foreground, so the tail of an older
    /// suspend never clears the state of a newer one.
    private var suspendID = 0

    init(model: SpeakerModel) {
        self.model = model
    }

    func phaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background:
            AppLog.lifecycle.info("phase: background")
            scheduleSuspend()
        case .active:
            AppLog.lifecycle.info("phase: active")
            suspendID += 1
            if pendingSuspend != nil {
                AppLog.lifecycle.info("pending suspend cancelled")
                pendingSuspend?.cancel()
                pendingSuspend = nil
            }
            endBackgroundTask()
            if model.isSuspended {
                AppLog.lifecycle.info("resume")
                model.resume()
            }
        case .inactive:
            AppLog.lifecycle.debug("phase: inactive")
        @unknown default:
            break
        }
    }

    private func scheduleSuspend() {
        guard pendingSuspend == nil, !model.isSuspended else { return }
        suspendID += 1
        let id = suspendID
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Suspend speaker connection") { [weak self] in
            // Out of background time: suspend at once rather than be killed mid-write.
            MainActor.assumeIsolated { self?.expire() }
        }
        pendingSuspend = Task { [weak self] in
            try? await Task.sleep(for: Self.suspendDelay)
            guard !Task.isCancelled, let self else { return }
            await self.suspendNow(id)
        }
    }

    private func suspendNow(_ id: Int) async {
        // Back in the foreground before this ran (the task `expire()` queues can run after a
        // thaw, once `.active` has already resumed): suspending now would drop the new session.
        guard id == suspendID, !Task.isCancelled else { return }
        AppLog.lifecycle.info("suspend")
        await model.suspend()
        guard id == suspendID else { return }  // back in the foreground meanwhile
        pendingSuspend = nil
        endBackgroundTask()
    }

    private func expire() {
        guard pendingSuspend != nil else { return endBackgroundTask() }
        pendingSuspend?.cancel()
        let id = suspendID
        pendingSuspend = Task { [weak self] in await self?.suspendNow(id) }
        // The task must end before the handler returns; the suspend finishes if it can.
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
