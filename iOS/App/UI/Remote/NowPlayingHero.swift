import KEFAppCore
import KEFKit
import SwiftUI

/// Artwork (or the speaker glyph), what's playing, and the transport buttons.
struct NowPlayingHero: View {
    let isLandscape: Bool
    /// Inside a scroll view (accessibility sizes): the artwork takes its width, not the
    /// height that is left.
    let scrolls: Bool

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let showsTrack = model.displaysNowPlaying
        let track = model.player.track
        VStack(spacing: 16) {
            ArtworkView(artwork: showsTrack ? model.artwork : nil, glyph: model.displaysOn ? .on : .standby)
                .frame(maxWidth: scrolls ? 280 : 400, maxHeight: scrolls ? nil : .infinity)
                .layoutPriority(-1)

            if !showsTrack, !(model.isOnline && !model.isOn) {
                // Nothing beside the caption: centre it.
                caption(showsTrack: false, track: nil, alignment: .center)
                    .frame(maxWidth: 560)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        caption(showsTrack: showsTrack, track: track, alignment: .leading)
                        Spacer(minLength: 0)
                        accessory(showsTrack: showsTrack)
                    }
                    VStack(spacing: 12) {
                        caption(showsTrack: showsTrack, track: track, alignment: .center)
                        accessory(showsTrack: showsTrack)
                    }
                }
                .frame(maxWidth: 560)
            }
        }
    }

    @ViewBuilder
    private func caption(showsTrack: Bool, track: Track?, alignment: HorizontalAlignment) -> some View {
        if showsTrack {
            TrackCaption(title: track?.title ?? "",
                         subtitle: [track?.artist, track?.album].compactMap { $0 }.filter { !$0.isEmpty }
                             .joined(separator: " — "),
                         alignment: alignment)
        } else {
            TrackCaption(title: sourceTitle, subtitle: sourceSubtitle, alignment: alignment)
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
            .buttonStyle(.glassProminent)
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

/// A square of artwork, or the glyph on the accent colour.
struct ArtworkView: View {
    let artwork: CGImage?
    let glyph: SpeakerGlyphShape.Style

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    ZStack {
                        Rectangle().fill(Color.accentColor.gradient)
                        SpeakerGlyph(style: glyph)
                            .foregroundStyle(.white.opacity(0.92))
                            .scaleEffect(0.48)
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            .animation(.easeInOut(duration: 0.35), value: artwork == nil)
            .accessibilityHidden(true)
    }
}

private struct TrackCaption: View {
    let title: String
    let subtitle: String
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
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
