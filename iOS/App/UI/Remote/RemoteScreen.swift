import KEFAppCore
import KEFKit
import SwiftUI

/// What the remote column shows.
enum RemotePhase: Equatable {
    /// No speaker known yet: "Find your speaker".
    case onboarding
    /// Local Network access is off.
    case localNetworkDenied
    /// Looking for or connecting to the speaker, with nothing to show yet.
    case searching
    /// The speaker can't be reached.
    case offline
    /// The remote itself; `readOnly` while it shows cached values and reconnects.
    case remote(readOnly: Bool)

    @MainActor init(model: SpeakerModel, ui: UIState, network: LocalNetworkMonitor) {
        let preferences = model.preferences
        let knowsSpeaker = model.hasCachedState || !preferences.lastHost.isEmpty
            || !preferences.knownSpeakers.isEmpty || preferences.hostMode == .manual
        if model.isOnline {
            self = .remote(readOnly: false)
        } else if network.isDenied {
            self = .localNetworkDenied
        } else if !knowsSpeaker {
            self = .onboarding
        } else if ui.showsOffline || model.connection.isOffline {
            self = .offline
        } else if model.hasCachedState {
            self = .remote(readOnly: true)
        } else {
            self = .searching
        }
    }

    var showsSpeakerChrome: Bool {
        switch self {
        case .onboarding, .localNetworkDenied: false
        case .searching, .offline, .remote: true
        }
    }
}

extension SpeakerModel.Connection {
    var isOffline: Bool {
        if case .offline = self { true } else { false }
    }

    /// The reason given when offline.
    var offlineReason: String? {
        if case .offline(let reason) = self { reason } else { nil }
    }
}

/// The remote column: the screen for the current phase, its title and power button, the
/// Sound and Settings bar, and the banners.
struct RemoteScreen: View {
    let layout: RemoteLayout

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(LocalNetworkMonitor.self) private var network

    var body: some View {
        let phase = RemotePhase(model: model, ui: ui, network: network)
        PhaseContent(phase: phase, layout: layout)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { RemoteBackdrop() }
            // Reconnecting shows in the title's status line (and the dimmed remote), not here.
            .overlay(alignment: .top) { BannerStack() }
            .toolbar {
                if phase.showsSpeakerChrome {
                    ToolbarItem(placement: .principal) { StatusTitle(phase: phase) }
                    if #available(iOS 27, *) {
                        ToolbarItem(placement: .topBarPinnedTrailing) { PowerButton() }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { PowerButton() }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                if case .remote = phase { PanelBar() }
            }
            .modifier(OfflineMemory())
    }
}

/// Keeps ``UIState/showsOffline`` in step with the connection.
private struct OfflineMemory: ViewModifier {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    func body(content: Content) -> some View {
        content.onChange(of: model.connection, initial: true) { _, connection in
            switch connection {
            case .offline(let reason):
                ui.showsOffline = true
                ui.lastOfflineReason = reason
            case .online: ui.showsOffline = false
            case .searching, .connecting: break
            }
        }
    }
}

private struct PhaseContent: View {
    let phase: RemotePhase
    let layout: RemoteLayout

    var body: some View {
        switch phase {
        case .onboarding: OnboardingView()
        case .localNetworkDenied: LocalNetworkDeniedView()
        case .searching: SearchingView()
        case .offline: OfflineView()
        case .remote(let readOnly): RemoteContent(layout: layout, readOnly: readOnly)
        }
    }
}

/// The speaker's name and status; tapping it opens Speakers.
private struct StatusTitle: View {
    let phase: RemotePhase

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.isWideLayout) private var isWide

    var body: some View {
        let status = statusLine
        Button {
            ui.open(.speakers, isWide: isWide)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(model.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.displayName)
        .accessibilityValue(status)
        .accessibilityHint("Choose speaker")
        .accessibilityAddTraits(.isButton)
    }

    private var statusLine: String {
        switch phase {
        case .remote(readOnly: true): "Connecting…"
        case .offline: "Offline"
        case .searching:
            if case .connecting = model.connection { "Connecting…" } else { "Looking for speaker…" }
        default: model.statusText
        }
    }

    private var dotColor: Color {
        guard model.isOnline else { return phase == .offline ? .red : .secondary }
        return model.isOn ? .green : .orange
    }
}

/// Standby / turn on, like the Mac's header button.
struct PowerButton: View {
    @Environment(SpeakerModel.self) private var model
    @State private var toggles = 0

    var body: some View {
        let isOn = model.isOn
        Button {
            toggles += 1
            model.togglePower()
        } label: {
            Image(systemName: "power")
                .fontWeight(.semibold)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .disabled(!model.isOnline)
        .accessibilityLabel(isOn ? "Put speaker in standby" : "Turn speaker on")
        .accessibilityHint(isOn ? "" : "Turns on with \(model.lastSource.displayName)")
        .sensoryFeedback(.impact(weight: .medium), trigger: toggles)
    }
}

/// A soft wash behind the remote: the artwork blurred, or the accent colour.
private struct RemoteBackdrop: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let artwork = model.displaysNowPlaying ? model.artwork : nil
        ZStack {
            Color(.systemBackground)
            if let artwork {
                Color.clear
                    .overlay {
                        Image(decorative: artwork, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 70, opaque: true)
                    }
                    .clipped()
                    .opacity(0.45)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.18), .clear],
                               startPoint: .top, endPoint: .center)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: model.artworkKey)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension SpeakerModel {
    /// On, judged from the values shown: live ones, or the cached ones while reconnecting
    /// (``isOn`` is false whenever the speaker isn't reachable right now).
    var displaysOn: Bool {
        (isOnline || hasCachedState) && source != nil && source != .standby
    }

    /// ``showsNowPlaying`` for the values shown, cached ones included.
    var displaysNowPlaying: Bool {
        displaysOn && (source == .wifi || source == .bluetooth) && player.hasMetadata
    }
}

extension SpeakerModel {
    /// The name shown is this speaker's: it was reached in this session, or it's the one
    /// found automatically. A typed address that hasn't answered yet has no name.
    var hasKnownName: Bool {
        !preferences.lastSpeakerName.isEmpty && (hasCachedState || preferences.hostMode == .automatic)
    }

    /// The speaker's name, or its address while it has none.
    var displayName: String {
        hasKnownName ? name : (host ?? "Speaker")
    }
}
