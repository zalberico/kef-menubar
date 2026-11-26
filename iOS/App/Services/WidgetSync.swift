import CoreGraphics
import Foundation
import KEFAppCore
import Observation
import WidgetKit

/// Keeps the widgets' snapshot in the App Group container current while the app runs:
/// when what the widgets show changes, it waits about a second for things to settle (a
/// volume drag, a track change and its artwork), writes the snapshot and reloads the
/// widgets, and the controls too when power or mute changed. Going to the background
/// writes at once, so the widgets have the last state before the app is suspended.
@MainActor
final class WidgetSync {
    static let debounce: Duration = .seconds(1)

    private let model: SpeakerModel
    private let store: SnapshotStore
    private var watcher: Task<Void, Never>?
    private var pendingWrite: Task<Void, Never>?
    /// What the controls showed at the last write (power, mute).
    private var lastControlState: ControlState?

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
                guard state != last else { continue }
                last = state
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
        do {
            try store.write(snapshot, artwork: model.artwork)
            WidgetCenter.shared.reloadAllTimelines()
            let controls = ControlState(isOn: snapshot.isOn, muted: snapshot.muted)
            if controls != lastControlState {
                lastControlState = controls
                ControlCenter.shared.reloadAllControls()
            }
        } catch {
            AppLog.lifecycle.error("widget snapshot not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct ControlState: Equatable {
    var isOn: Bool
    var muted: Bool
}

/// What the widgets show, compared without its timestamp so only real changes are written.
private struct WidgetState: Equatable, Sendable {
    var snapshot: SpeakerSnapshot?
    var hasArtwork: Bool

    @MainActor init(model: SpeakerModel) {
        snapshot = model.snapshot(at: .distantPast)
        hasArtwork = model.artwork != nil
    }
}
