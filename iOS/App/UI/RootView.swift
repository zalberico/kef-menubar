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
    /// The window's size without the keyboard: the layout must not change when a text field
    /// in the wide layout's column raises it (that would remove the field it is typing in).
    @State private var layoutSize: CGSize?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        // The GeometryReader takes the window's size whatever its content's size, and its
        // background measures that plus the keyboard's height: the content still avoids the
        // keyboard. (Measuring inside the content's own stack would feed its size back.)
        GeometryReader { _ in
            if let layoutSize {
                AdaptiveRoot(
                    layout: RemoteLayout(size: layoutSize, verticalSizeClass: verticalSizeClass),
                    width: layoutSize.width)
            }
        }
        .background {
            Color.clear
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    layoutSize = size
                }
                .ignoresSafeArea(.keyboard)
        }
        .environment(ui)
        .background {
            if networkMonitoring { NetworkMonitorDriver() }
        }
        .background { CommandHaptics() }
    }
}

/// The haptics of what the speaker did with a command, in one place for the remote, the
/// vertical bar, Sound and Settings: success once it confirms a mute, power or input
/// change (never on the tap itself), an error when a command fails (with its banner).
private struct CommandHaptics: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        Color.clear
            .sensoryFeedback(.success, trigger: model.confirmedChanges.total)
            .sensoryFeedback(.error, trigger: model.failedCommands)
            .accessibilityHidden(true)
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
