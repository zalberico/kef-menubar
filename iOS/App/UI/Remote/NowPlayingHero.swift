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

    var body: some View {
        let showsTrack = model.displaysNowPlaying
        let track = model.player.track
        VStack(spacing: 16) {
            ArtworkView(artwork: showsTrack ? model.artwork : nil, isAsleep: !model.displaysOn)
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
            Button {
                model.togglePower()
            } label: {
                Label("Turn On (\(model.lastSource.displayName))", systemImage: "power")
                    .fontWeight(.semibold)
            }
            .prominentGlassStyle()
            .controlSize(.large)
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
/// full-colour cabinet in the same square, asleep in standby.
struct ArtworkView: View {
    let artwork: CGImage?
    let isAsleep: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipShape(ArtworkShape())
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                        .transition(.opacity)
                } else {
                    CabinetTile(isAsleep: isAsleep)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: artwork == nil)
            .accessibilityHidden(true)
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
