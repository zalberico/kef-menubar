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
                                ui.closeSheet()
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
        case .sound: SoundPanel()
        case .settings: SettingsPanel()
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
