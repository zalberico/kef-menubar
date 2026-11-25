import KEFAppCore
import KEFKit
import SwiftUI

/// A panel in its own navigation stack, as a sheet (compact) or the side column (wide).
/// The path lives in ``UIState``, so it survives the move between the two.
struct PanelStack: View {
    let panel: UIState.Panel
    let isSheet: Bool

    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        NavigationStack(path: $ui.panelPath) {
            PanelContent(panel: panel)
                .navigationBarTitleDisplayMode(isSheet ? .inline : .large)
                .toolbar {
                    if isSheet {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) {
                                ui.isSheetPresented = false
                            }
                        }
                    }
                }
                #if DEBUG || PROBE
                .navigationDestination(for: UIState.Route.self) { route in
                    RouteView(route: route)
                }
                #endif
        }
    }
}

private struct PanelContent: View {
    let panel: UIState.Panel

    var body: some View {
        switch panel {
        case .speakers: SpeakersPanel()
        case .sound:
            PanelPlaceholder(title: "Sound", symbol: "slider.horizontal.3",
                             message: "Sound settings arrive in the next build.")
        case .settings: SettingsPlaceholder()
        }
    }
}

#if DEBUG || PROBE
private struct RouteView: View {
    let route: UIState.Route

    var body: some View {
        switch route {
        case .diagnostics: DiagnosticsView()
        }
    }
}
#endif

private struct SettingsPlaceholder: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        PanelPlaceholder(
            title: "Settings", symbol: "gearshape",
            message: model.firmwareUpdateAvailable
                ? "Speaker settings arrive in a later build. A firmware update is available for \(model.name); you can install it from KEF Connect for now."
                : "Speaker settings arrive in a later build.")
    }
}

private struct PanelPlaceholder: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView("Coming Soon", systemImage: symbol, description: Text(message))
            .navigationTitle(title)
    }
}
