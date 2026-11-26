import KEFAppCore
import SwiftUI

/// How the window's space is used, chosen from its size alone (never the device type),
/// checked in this order.
enum RemoteLayout: Equatable {
    /// Remote and a panel column side by side (the Duo's inner screen, large windows).
    case wide
    /// Little height: now playing on the left, the controls on the right.
    case landscape
    /// One column (portrait iPhone, the Duo's outer screen).
    case compact

    init(size: CGSize, verticalSizeClass: UserInterfaceSizeClass?) {
        if size.width >= 640, size.height >= 500 {
            self = .wide
        } else if verticalSizeClass == .compact {
            self = .landscape
        } else {
            self = .compact
        }
    }

    /// The remote column's width in the wide layout: about 45%, at least 300 pt.
    static func remoteColumnWidth(for width: CGFloat) -> CGFloat {
        max(300, (width * 0.45).rounded())
    }
}

extension EnvironmentValues {
    /// The window uses the wide layout (panels open in the side column, not a sheet).
    @Entry var isWideLayout = false
}

/// One window: its ``UIState`` (above every layout branch), the adaptive layout, and the
/// Local Network check while the speaker can't be reached.
struct RootView: View {
    /// Off in the demo, which never touches the network.
    let networkMonitoring: Bool

    @State private var ui = UIState()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            AdaptiveRoot(
                layout: RemoteLayout(size: proxy.size, verticalSizeClass: verticalSizeClass),
                width: proxy.size.width)
        }
        .environment(ui)
        .background {
            if networkMonitoring { NetworkMonitorDriver() }
        }
    }
}

/// The remote, plus the panel as a column (wide) or a sheet (compact and landscape). The
/// remote's navigation stack keeps its identity across every layout; the panel's stack is
/// a sibling, never nested.
private struct AdaptiveRoot: View {
    let layout: RemoteLayout
    let width: CGFloat

    @Environment(UIState.self) private var ui

    var body: some View {
        let isWide = layout == .wide
        HStack(spacing: 0) {
            NavigationStack {
                RemoteScreen(layout: layout)
            }
            .frame(width: isWide ? RemoteLayout.remoteColumnWidth(for: width) : nil)

            if isWide {
                Divider().ignoresSafeArea()
                PanelStack(panel: ui.columnPanel, isSheet: false)
                    .frame(minWidth: 340)
            }
        }
        .environment(\.isWideLayout, isWide)
        .sheet(isPresented: ui.sheetBinding(isWide: isWide)) {
            PanelStack(panel: ui.panel ?? .sound, isSheet: true)
                .presentationDetents([.medium, .large])
                .environment(\.isWideLayout, false)
        }
        .onChange(of: isWide, initial: true) { _, wide in
            ui.layoutChanged(isWide: wide)
        }
    }
}

/// Watches for a Local Network denial only while the speaker isn't reachable (a reachable
/// speaker proves access), so the app isn't browsing Bonjour the rest of the time.
private struct NetworkMonitorDriver: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(LocalNetworkMonitor.self) private var network

    var body: some View {
        Color.clear
            .task(id: model.isOnline) {
                if model.isOnline { network.stop() } else { network.start() }
            }
    }
}
