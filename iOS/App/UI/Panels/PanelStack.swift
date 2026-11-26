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
                .modifier(PanelColumnChrome(isSheet: isSheet))
                #if DEBUG || PROBE
                .navigationDestination(for: UIState.Route.self) { route in
                    // The pushed view's toolbar replaces the root's in the bar, so it
                    // carries the chrome too (or the vertical bar would show only Back).
                    RouteView(route: route)
                        .modifier(PanelColumnChrome(isSheet: isSheet))
                }
                #endif
        }
    }
}

/// In the wide layout, the side column's toolbar carries the remote's chrome when the
/// system's vertical bar is on the column's edge (the bar shows the items beside it).
private struct PanelColumnChrome: ViewModifier {
    let isSheet: Bool

    @Environment(\.isWideLayout) private var isWide
    @Environment(UIState.self) private var ui

    func body(content: Content) -> some View {
        VerticalBarEdgeReader { edge in
            let besideBar = !isSheet && isWide && edge != nil
            content
                .modifier(RemoteChromeToolbar(
                    isShown: !isSheet && ChromeColumn(verticalBarEdge: edge, isWide: isWide) == .panel))
                // Tell the remote column, which can't see the bar, that power is in it.
                .onChange(of: besideBar, initial: true) { _, beside in
                    if !isSheet { ui.sideColumnHasVerticalBar = beside }
                }
                .onDisappear {
                    if !isSheet { ui.sideColumnHasVerticalBar = false }
                }
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
