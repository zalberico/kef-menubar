import KEFAppCore
import SwiftUI
import WidgetKit

@main
struct RemoteApp: App {
    /// The one live connection to the speaker, shared by every scene.
    @State private var model: SpeakerModel

    init() {
        model = SpeakerModel(
            preferences: Preferences(defaults: AppGroup.defaults()),
            logSubsystem: Bundle.main.bundleIdentifier ?? "Speakeasy")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Starts the model, follows the app's lifecycle, and keeps the widgets' snapshot current.
private struct RootView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RemoteView()
            .task { model.start() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: Task { await model.suspend() }
                case .active: if model.isSuspended { model.resume() }
                default: break
                }
            }
            .onChange(of: WidgetState(model: model)) { _, state in
                publish(state.snapshot)
            }
    }

    private func publish(_ snapshot: SpeakerSnapshot?) {
        guard var snapshot, let store = AppGroup.snapshotStore else { return }
        snapshot.updatedAt = .now
        try? store.write(snapshot, artwork: model.artwork)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// What the widgets show, compared without its timestamp so only real changes are written.
private struct WidgetState: Equatable {
    var snapshot: SpeakerSnapshot?
    var hasArtwork: Bool

    @MainActor init(model: SpeakerModel) {
        snapshot = model.snapshot(at: .distantPast)
        hasArtwork = model.artwork != nil
    }
}
