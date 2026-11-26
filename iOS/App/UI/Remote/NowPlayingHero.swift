import KEFAppCore
import KEFKit
import SwiftUI

/// Artwork (or the speaker cabinet), what's playing, and the transport buttons (or Turn On),
/// always stacked and centred so the layout never changes with the length of a title.
struct NowPlayingHero: View {
    /// Inside a scroll view (accessibility sizes): the artwork takes its width, not the
    /// height that is left, and stays a thumbnail so volume starts on the first screen.
    let scrolls: Bool

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        let showsTrack = model.displaysNowPlaying
        let track = model.player.track
        VStack(spacing: 16) {
            ArtworkView(artwork: showsTrack ? model.artwork : nil,
                        expectsArtwork: showsTrack && track?.artworkURL != nil,
                        isAsleep: !model.displaysOn)
                .modifier(TrackSwipe(canPrevious: showsTrack && model.player.canPrevious,
                                     canNext: showsTrack && model.player.canNext,
                                     skip: { command in model.control(command) }))
                .frame(maxWidth: scrolls ? 104 : 400, maxHeight: scrolls ? nil : .infinity)
                .layoutPriority(-1)

            VStack(spacing: 12) {
                caption(showsTrack: showsTrack, track: track)
                accessory(showsTrack: showsTrack)
            }
            .frame(maxWidth: 560)
        }
    }

    @ViewBuilder
    private func caption(showsTrack: Bool, track: Track?) -> some View {
        if showsTrack {
            TrackCaption(title: track?.title ?? "",
                         subtitle: [track?.artist, track?.album].compactMap { $0 }.filter { !$0.isEmpty }
                             .joined(separator: " — "))
                // The artwork's swipe, for VoiceOver (the artwork itself is hidden from it).
                .accessibilityActions {
                    if model.player.canNext {
                        Button("Next Track") { model.control(.next) }
                    }
                    if model.player.canPrevious {
                        Button("Previous Track") { model.control(.previous) }
                    }
                }
        } else {
            TrackCaption(title: sourceTitle, subtitle: sourceSubtitle)
        }
    }

    @ViewBuilder
    private func accessory(showsTrack: Bool) -> some View {
        if showsTrack {
            TransportControls(canPrevious: model.player.canPrevious, canPause: model.player.canPause,
                              isPlaying: model.player.isPlaying, canNext: model.player.canNext)
        } else if model.isOnline, !model.isOn {
            // With a vertical bar (iPhone Duo) power always lives in the bar instead: beside
            // this column (closed), or beside the side column (open, wide layout).
            VerticalBarEdgeReader { edge in
                if edge == nil, !ui.sideColumnHasVerticalBar {
                    Button {
                        model.togglePower()
                    } label: {
                        Label("Turn On", systemImage: "power")
                            .fontWeight(.semibold)
                    }
                    .accessibilityHint("Turns on with \(model.lastSource.displayName)")
                    .prominentGlassStyle()
                    .controlSize(.large)
                }
            }
        }
    }

    private var sourceTitle: String {
        guard model.displaysOn, let source = model.source else { return "Standby" }
        switch source {
        case .wifi: return "Wi-Fi / AirPlay"
        case .bluetooth: return "Bluetooth"
        default: return "Playing from \(source.displayName)"
        }
    }

    private var sourceSubtitle: String {
        guard model.displaysOn, let source = model.source else { return model.name }
        return source == .wifi || source == .bluetooth ? "Nothing playing" : model.name
    }
}

/// A square of artwork or, with none (TV, optical, nothing playing, standby), the
/// full-colour cabinet in the same square, asleep in standby. A new track's artwork
/// crossfades over the last one: while it loads (the model has none for a moment) the
/// last one stays up, for at most 1.5 s, instead of flashing the cabinet in between.
struct ArtworkView: View {
    let artwork: CGImage?
    /// The track shown has artwork, maybe still loading.
    var expectsArtwork = false
    let isAsleep: Bool

    /// The last artwork shown, kept while the next one loads.
    @State private var held: CGImage?

    var body: some View {
        let shown = artwork ?? (expectsArtwork ? held : nil)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let shown {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .clipShape(ArtworkShape())
                            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                            .id(ObjectIdentifier(shown))
                            .transition(.opacity)
                    } else {
                        CabinetTile(isAsleep: isAsleep)
                            .transition(.opacity)
                    }
                }
            }
            // A dissolve, which stays with Reduce Motion (it doesn't move anything).
            .animation(.easeInOut(duration: 0.45), value: shown.map(ObjectIdentifier.init))
            .onChange(of: artwork.map(ObjectIdentifier.init), initial: true) {
                if let artwork { held = artwork }
            }
            .onChange(of: expectsArtwork) { _, expects in
                // The speaker graphic took over: the last cover bridges consecutive tracks
                // only, and doesn't come back after it.
                if !expects { held = nil }
            }
            .task(id: artwork == nil && expectsArtwork) {
                // Waiting for artwork: give up on the last one after a moment (a failed load).
                guard artwork == nil, expectsArtwork, held != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { held = nil }
            }
            .accessibilityHidden(true)
    }
}

/// A horizontal swipe on the artwork for the next track (towards the leading edge) or the
/// previous one, when the source allows it. The artwork leans a little with the finger
/// (not with Reduce Motion); a light haptic when it skips. The buttons stay, and VoiceOver
/// gets the caption's actions instead.
private struct TrackSwipe: ViewModifier {
    let canPrevious: Bool
    let canNext: Bool
    let skip: (PlayerCommand) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.35, bounce: 0.3)))
    private var lean: CGFloat = 0
    @State private var skips = 0

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : lean)
            .simultaneousGesture(swipe, isEnabled: canPrevious || canNext)
            .sensoryFeedback(.impact(weight: .light), trigger: skips)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($lean) { value, lean, _ in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                // Follows the finger at a third of the way, less in a direction that can't skip.
                let allowed = dx < 0 ? canNext : canPrevious
                let limit: CGFloat = allowed ? 44 : 12
                lean = max(-limit, min(limit, dx / (allowed ? 3 : 8)))
            }
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.5 else { return }
                // Far enough, or a quick flick.
                guard abs(dx) > 70 || abs(value.predictedEndTranslation.width) > 180 else { return }
                if dx < 0, canNext {
                    skips += 1
                    skip(.next)
                } else if dx > 0, canPrevious {
                    skips += 1
                    skip(.previous)
                }
            }
    }
}

/// A rounded square whose corners shrink with it, so small artwork (landscape, a long
/// title) stays a rounded square rather than turning into a circle.
private struct ArtworkShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(28, rect.width * 0.12), style: .continuous)
    }
}

/// Title and subtitle, wrapping onto a second line (a third for the title at accessibility
/// sizes) before they truncate.
private struct TrackCaption: View {
    let title: String
    let subtitle: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }
}

/// Previous, play/pause and next, as far as the source allows them.
private struct TransportControls: View {
    let canPrevious: Bool
    let canPause: Bool
    let isPlaying: Bool
    let canNext: Bool

    @Environment(SpeakerModel.self) private var model
    @State private var taps = 0

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                button("backward.fill", label: "Previous Track", enabled: canPrevious, size: 40) { model.control(.previous) }
                button(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play",
                       enabled: canPause, size: 50) { model.control(.pause) }
                button("forward.fill", label: "Next Track", enabled: canNext, size: 40) { model.control(.next) }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func button(_ symbol: String, label: String, enabled: Bool, size: CGFloat,
                        action: @escaping () -> Void) -> some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(size > 45 ? .title2 : .body)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}
