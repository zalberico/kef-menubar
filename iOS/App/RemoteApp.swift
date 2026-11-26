import KEFAppCore
import KEFKit
import SwiftUI

@main
struct RemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase

    /// The one live connection to the speaker, for the app's lifetime and every scene.
    @State private var model: SpeakerModel
    @State private var network: LocalNetworkMonitor
    @State private var services: Services

    init() {
        let model: SpeakerModel
        var isDemo = false
        #if DEBUG
        if DemoSpeaker.isEnabled {
            model = DemoSpeaker.makeModel()
            isDemo = true
        } else {
            model = Self.makeModel()
        }
        DemoSpeaker.setIntentsUseDemo(isDemo && DemoSpeaker.intentsArgument)
        #else
        model = Self.makeModel()
        #endif
        if AppGroup.containerURL == nil {
            // Widgets, controls and Shortcuts would never see the speaker. Only broken
            // signing (no App Group entitlement) gets here.
            AppLog.lifecycle.error("App Group \(AppGroup.identifier, privacy: .public) is unavailable; widgets and intents will not see the speaker")
            assertionFailure("App Group container is missing: check the App Group entitlement")
        }
        let network = LocalNetworkMonitor()
        network.onAllowed = { [weak model] in model?.retry() }
        self.model = model
        self.network = network
        var demoFeedsWidgets = false
        #if DEBUG
        demoFeedsWidgets = isDemo && DemoSpeaker.intentsArgument
        #endif
        services = Services(model: model, isDemo: isDemo, demoFeedsWidgets: demoFeedsWidgets)
    }

    private static func makeModel() -> SpeakerModel {
        SpeakerModel(
            preferences: Preferences(defaults: AppGroup.defaults()),
            logSubsystem: AppLog.subsystem,
            discover: {
                AppLog.discovery.info("bonjour scan started")
                let found = await KEFDiscovery.discover()
                AppLog.discovery.info("bonjour scan found \(found.count) speaker(s)")
                return found
            })
    }

    var body: some Scene {
        WindowGroup {
            RootView(networkMonitoring: !services.isDemo)
                .environment(model)
                .environment(network)
                .task {
                    model.start()
                    services.widgetSync?.start()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { services.widgetSync?.flush() }
            services.lifecycle.phaseChanged(to: phase)
            network.setActive(phase == .active)
        }
    }
}

/// The app-wide helpers around the model, made once.
@MainActor
final class Services {
    let lifecycle: Lifecycle
    /// `nil` in the demo, which must not overwrite the real speaker's widget snapshot,
    /// unless the demo also feeds the widgets and intents (`-DemoIntents YES`, debug only).
    let widgetSync: WidgetSync?
    let isDemo: Bool

    init(model: SpeakerModel, isDemo: Bool, demoFeedsWidgets: Bool = false) {
        lifecycle = Lifecycle(model: model)
        widgetSync = isDemo && !demoFeedsWidgets ? nil : AppGroup.snapshotStore.map { WidgetSync(model: model, store: $0) }
        self.isDemo = isDemo
    }
}
