import KEFAppCore
import SwiftUI
import UIKit

/// Which column's toolbar puts the remote's chrome (mute, power, Sound, Settings, Speakers)
/// in the system's vertical bar (iOS 27.1). The bar shows the items of the navigation bar
/// beside it: the remote's own in one column, the panel column's when the wide layout puts
/// that column on the bar's (trailing) edge.
enum ChromeColumn: Equatable {
    case remote
    case panel

    /// `nil` without a vertical bar: the chrome stays in the top bar and the bottom bar.
    init?(verticalBarEdge: HorizontalEdge?, isWide: Bool) {
        guard let verticalBarEdge else { return nil }
        self = isWide && verticalBarEdge == .trailing ? .panel : .remote
    }
}

/// Hands its content the edge holding the system's vertical bar, `nil` without one (and
/// before iOS 27.1). Read from the environment where the toolbar is built, never from the
/// device: the bar comes and goes with the window's configuration (folding, rotating),
/// not with the hardware.
struct VerticalBarEdgeReader<Content: View>: View {
    @ViewBuilder let content: (_ edge: HorizontalEdge?) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            ToolbarVerticalEdgeReader(content: content)
        } else {
            content(nil)
        }
    }
}

@available(iOS 27.1, *)
private struct ToolbarVerticalEdgeReader<Content: View>: View {
    let content: (HorizontalEdge?) -> Content

    @Environment(\.toolbarVerticalEdge) private var edge

    var body: some View {
        content(edge)
    }
}

/// Adds the remote's chrome to this view's toolbar, for the vertical bar, when `isShown`.
struct RemoteChromeToolbar: ViewModifier {
    let isShown: Bool

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(LocalNetworkMonitor.self) private var network
    @Environment(\.isWideLayout) private var isWide

    func body(content: Content) -> some View {
        let phase = RemotePhase(model: model, ui: ui, network: network)
        // Read here and passed in as values, so a change redraws the items.
        let isWide = isWide
        content.toolbar {
            if isShown, phase.showsSpeakerChrome {
                if #available(iOS 27.1, *) {
                    RemoteChromeItems(
                        showsRemoteControls: phase.isRemote,
                        isOn: model.isOn,
                        firmwareUpdateAvailable: model.firmwareUpdateAvailable,
                        selectedPanel: isWide ? ui.columnPanel : nil,
                        open: { panel in ui.open(panel, isWide: isWide) })
                }
            }
        }
    }
}

extension RemotePhase {
    /// The remote itself (live or reconnecting), not one of the state screens.
    var isRemote: Bool {
        if case .remote = self { true } else { false }
    }
}

/// The remote's chrome in the vertical bar, most important first: the system shows the
/// items top down and moves the ones that don't fit (a Live Activity can take the bottom
/// of the bar) into its overflow menu, lowest priority first. Symbols only, like every
/// item in that bar; each has a spoken label. Sound, Settings and Speakers sit directly in
/// their items (not in a view of their own) so the bar can draw the Settings badge.
@available(iOS 27.1, *)
private struct RemoteChromeItems: ToolbarContent {
    /// Mute, power, Sound and Settings (the remote, not a state screen like Offline).
    let showsRemoteControls: Bool
    let isOn: Bool
    let firmwareUpdateAvailable: Bool
    /// The panel the wide layout's side column shows (drawn selected); `nil` otherwise.
    let selectedPanel: UIState.Panel?
    let open: (UIState.Panel) -> Void

    var body: some ToolbarContent {
        if showsRemoteControls {
            ToolbarItem(placement: .primaryAction) { MuteBarButton() }
                .visibilityPriority(.high)
            // Power always lives in the bar (on and in standby), so it never moves; the hero
            // drops its Turn On button while a vertical bar is shown.
            ToolbarItem(placement: .primaryAction) { BarPowerButton() }
                .visibilityPriority(.high)
            panelItem(.sound)
            panelItem(.settings)
        }
        panelItem(.speakers)
            .visibilityPriority(.low)
    }

    @ToolbarContentBuilder
    private func panelItem(_ panel: UIState.Panel) -> some ToolbarContent {
        let isSelected = selectedPanel == panel
        // The bar draws a badge as a red alert: one update waiting. A badge that changes on
        // an item already in the bar isn't redrawn, so each look is an item of its own.
        let hasBadge = panel == .settings && firmwareUpdateAvailable
        if isSelected, hasBadge {
            ToolbarItem(placement: .primaryAction) { selected(panelButton(panel, hasBadge: true, isSelected: true)) }
        } else if isSelected {
            ToolbarItem(placement: .primaryAction) { selected(panelButton(panel, hasBadge: false, isSelected: true)) }
        } else if hasBadge {
            ToolbarItem(placement: .primaryAction) { panelButton(panel, hasBadge: true, isSelected: false) }
        } else {
            ToolbarItem(placement: .primaryAction) { panelButton(panel, hasBadge: false, isSelected: false) }
        }
    }

    private func panelButton(_ panel: UIState.Panel, hasBadge: Bool, isSelected: Bool) -> some View {
        Button {
            open(panel)
        } label: {
            Label {
                Text(panel.title)
            } icon: {
                if isSelected, let symbol = Self.prominentSymbol(panel.symbol) {
                    Image(uiImage: symbol)
                } else {
                    Image(systemName: panel.symbol)
                }
            }
        }
        .badge(hasBadge ? 1 : 0)
        .accessibilityValue(hasBadge ? "Firmware update available" : "")
    }

    /// The symbol in the readable label colour for the amber fill (near-black in dark mode).
    /// The bar draws its items' symbols in its own colour, ignoring the foreground style,
    /// so the colour is baked into the image; the dynamic colour still follows the
    /// appearance and Increase Contrast.
    private static func prominentSymbol(_ name: String) -> UIImage? {
        UIImage(systemName: name)?
            .withTintColor(UIColor(resource: .prominentLabel), renderingMode: .alwaysOriginal)
    }

    private func selected(_ button: some View) -> some View {
        // As for every other selected control (the symbol carries the label colour itself).
        button
            .prominentGlassStyle()
            .accessibilityAddTraits(.isSelected)
    }
}

extension UIState.Panel {
    /// The panel's name, as its button says it.
    var title: String {
        switch self {
        case .sound: "Sound"
        case .settings: "Settings"
        case .speakers: "Speakers"
        }
    }

    var symbol: String {
        switch self {
        case .sound: "slider.horizontal.3"
        case .settings: "gearshape"
        case .speakers: "hifispeaker.2"
        }
    }
}

/// Symbols with their colour baked in: the vertical bar draws items in its own colour and
/// shows no disabled dimming, so a state colour has to be part of the image.
private enum BarSymbol {
    static func image(_ name: String, _ color: UIColor) -> Image {
        if let symbol = UIImage(systemName: name)?.withTintColor(color, renderingMode: .alwaysOriginal) {
            return Image(uiImage: symbol)
        }
        return Image(systemName: name)
    }

    static var accent: UIColor { UIColor(named: "AccentColor") ?? .tintColor }
}

/// Mute in the vertical bar: saffron while muted, faint while it can't be used (the speaker
/// is off or an input is settling).
private struct MuteBarButton: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let muted = model.muted
        let usable = model.isOn && !model.inputSettling
        let name = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        Button {
            model.toggleMute()
        } label: {
            if !usable {
                BarSymbol.image(name, .tertiaryLabel)
            } else if muted {
                BarSymbol.image(name, BarSymbol.accent)
            } else {
                MuteSymbol(muted: false)
            }
        }
        .disabled(!usable)
        // A toggle: VoiceOver reads "Mute, switch button, on" while muted.
        .accessibilityLabel("Mute")
        .accessibilityAddTraits(muted ? [.isToggle, .isSelected] : .isToggle)
    }
}

/// Power in the vertical bar, in both states: saffron while on, the bar's own colour in
/// standby (still clearly tappable), faint while the speaker can't be reached.
private struct BarPowerButton: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let isOn = model.isOn
        Button {
            model.togglePower()
        } label: {
            if !model.isOnline {
                BarSymbol.image("power", .tertiaryLabel)
            } else if isOn {
                BarSymbol.image("power", BarSymbol.accent)
            } else {
                Image(systemName: "power")
            }
        }
        .disabled(!model.isOnline)
        .accessibilityLabel(isOn ? "Put speaker in standby" : "Turn speaker on")
        .accessibilityHint(isOn ? "" : "Turns on with \(model.lastSource.displayName)")
    }
}
