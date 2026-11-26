import CoreGraphics
import Foundation
import KEFAppCore
import Observation
import WidgetKit

/// Keeps the widgets' snapshot in the App Group container current while the app runs:
/// when what the widgets show changes, it waits about a second for things to settle (a
/// volume drag, a track change and its artwork), writes the snapshot and reloads the
/// widgets, and the controls too when what they show (power, mute, the name) changed. Going
/// to the background writes at once, so the widgets have the last state before the app is
/// suspended. Coming back online always writes once: the extension (an intent, a control)
/// may have written the store meanwhile, so the app's own last state says nothing about
/// what is stored.
@MainActor
final class WidgetSync {
    static let debounce: Duration = .seconds(1)

    private let model: SpeakerModel
    private let store: SnapshotStore
    private var watcher: Task<Void, Never>?
    private var pendingWrite: Task<Void, Never>?

    init(model: SpeakerModel, store: SnapshotStore) {
        self.model = model
        self.store = store
    }

    func start() {
        guard watcher == nil else { return }
        let model = model
        watcher = Task { [weak self] in
            var last: WidgetState?
            for await state in Observations({ @MainActor in WidgetState(model: model) }) {
                let changed = state.content != last?.content
                let cameOnline = state.isOnline && last?.isOnline != true
                last = state
                guard changed || cameOnline else { continue }
                self?.scheduleWrite()
            }
        }
    }

    /// Write now if a write is waiting (the app is going to the background).
    func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        write()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.pendingWrite = nil
            self?.write()
        }
    }

    private func write() {
        guard let snapshot = model.snapshot(at: .now) else { return }
        // Compared with what is stored, whoever wrote it (this app or the extension).
        let stored = store.read().map(ControlState.init)
        do {
            try store.write(snapshot, artwork: model.artwork)
            WidgetCenter.shared.reloadAllTimelines()
            if stored != ControlState(snapshot) {
                ControlCenter.shared.reloadAllControls()
            }
        } catch {
            AppLog.lifecycle.error("widget snapshot not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What the controls show: power, mute, and the speaker's name (the Power control's title).
private struct ControlState: Equatable {
    var isOn: Bool
    var muted: Bool
    var name: String

    init(_ snapshot: SpeakerSnapshot) {
        isOn = snapshot.isOn
        muted = snapshot.muted
        name = snapshot.name
    }
}

/// What the widgets show, compared without its timestamp so only real changes are written,
/// and whether the model is online (coming back online writes once).
private struct WidgetState: Equatable, Sendable {
    struct Content: Equatable, Sendable {
        var snapshot: SpeakerSnapshot?
        var hasArtwork: Bool
    }

    var content: Content
    var isOnline: Bool

    @MainActor init(model: SpeakerModel) {
        content = Content(snapshot: model.snapshot(at: .distantPast), hasArtwork: model.artwork != nil)
        isOnline = model.isOnline
    }
}
