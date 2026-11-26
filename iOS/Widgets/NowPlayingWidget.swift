import AppIntents
import KEFAppCore
import KEFKit
import SwiftUI
import WidgetKit

/// The speaker's track and volume on the Home Screen (small and medium, the medium one with
/// volume buttons) and the Lock Screen. It shows the snapshot the app and the intents keep
/// in the App Group, after one quick fresh read; artwork comes only from the stored file.
/// Tapping it opens the app.
struct NowPlayingWidget: Widget {
    static let kind = "NowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingProvider()) { entry in
            NowPlayingView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What your speaker is playing, and its volume.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct NowPlayingEntry: TimelineEntry {
    enum Status: Equatable {
        /// The app hasn't found a speaker yet.
        case noSpeaker
        /// The last read failed: shown asleep, with the last known name.
        case offline
        case standby
        case on
    }

    let date: Date
    let snapshot: SpeakerSnapshot?
    let artwork: CGImage?
    let status: Status

    init(date: Date = .now, snapshot: SpeakerSnapshot?, artwork: CGImage? = nil, readFailed: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.artwork = artwork
        status = if snapshot == nil { .noSpeaker } else if readFailed { .offline } else if snapshot?.isOn == true { .on } else { .standby }
    }

    static let preview = NowPlayingEntry(snapshot: .preview)
}

struct NowPlayingProvider: TimelineProvider {
    /// Widgets are also reloaded by the app and by every intent.
    static let refresh: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> NowPlayingEntry {
        .preview
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        // The gallery and transitions: the stored snapshot, no network.
        guard let snapshot = AppGroup.snapshotStore?.read() else {
            completion(context.isPreview ? .preview : NowPlayingEntry(snapshot: nil))
            return
        }
        completion(NowPlayingEntry(snapshot: snapshot, artwork: Self.artwork(for: snapshot)))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        Task {
            let reading = await SpeakerAccess.currentSnapshot()
            let entry = NowPlayingEntry(snapshot: reading.snapshot, artwork: reading.snapshot.flatMap(Self.artwork(for:)),
                                        readFailed: reading.readFailed)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.refresh))))
        }
    }

    private static func artwork(for snapshot: SpeakerSnapshot) -> CGImage? {
        AppGroup.snapshotStore?.readArtwork(key: snapshot.artworkKey)
    }
}

// MARK: Views

struct NowPlayingView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .systemSmall || family == .systemMedium {
                    TealBackground(isAsleep: entry.status != .on)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: CircularView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline: InlineView(entry: entry)
        case .systemMedium: MediumView(entry: entry).environment(\.colorScheme, fullColorScheme)
        default: SmallView(entry: entry).environment(\.colorScheme, fullColorScheme)
        }
    }

    /// Light text on the teal background; tinted and clear modes (and StandBy at night)
    /// keep the system's.
    private var fullColorScheme: ColorScheme { renderingMode == .fullColor ? .dark : systemColorScheme }
}

/// The icon's teal, slate grey when asleep (like ``CabinetTile``).
private struct TealBackground: View {
    let isAsleep: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [BrandTeal.top, BrandTeal.bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [BrandTeal.glow.opacity(0.45), .clear],
                           center: UnitPoint(x: 0.2, y: 0.15), startRadius: 0, endRadius: 220)
        }
        .saturation(isAsleep ? 0.25 : 1)
    }
}

/// The track's artwork, else the cabinet itself (the widget is already the icon's teal),
/// asleep in standby and offline. Tinted and clear Home Screens and StandBy at night draw
/// in one colour, so there the cabinet is the monochrome glyph.
private struct ArtworkTile: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if let artwork = entry.artwork, entry.status == .on {
            Image(decorative: artwork, scale: 1)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(CabinetTileShape())
        } else if renderingMode == .fullColor {
            CabinetArt(isAsleep: entry.status != .on)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
        } else {
            SpeakerGlyph(style: glyphStyle)
                .padding(4)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .widgetAccentable(entry.status == .on)
        }
    }

    private var glyphStyle: SpeakerGlyphShape.Style {
        switch entry.status {
        case .on: .on
        case .offline: .offline
        case .standby, .noSpeaker: .standby
        }
    }
}

/// The name, the title (or the state) and the artist.
private struct Caption: View {
    let entry: NowPlayingEntry
    var titleLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch entry.status {
            case .noSpeaker:
                Text("Speakeasy").font(.headline)
                Text("Open the app to find your speaker.").font(.caption).foregroundStyle(.secondary)
            case .offline:
                Text("Can't Reach").font(.headline)
                name
            case .standby:
                Text("Standby").font(.headline)
                name
            case .on:
                if let title = entry.snapshot?.title {
                    Text(verbatim: title)
                        .font(.headline)
                        .lineLimit(titleLines)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    if let artist = entry.snapshot?.artist {
                        Text(verbatim: artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(verbatim: entry.snapshot?.input?.shortName ?? "On").font(.headline)
                    name
                }
            }
        }
    }

    private var name: some View {
        Text(verbatim: entry.snapshot?.name ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// "speaker 24", or muted.
private struct VolumeLabel: View {
    let snapshot: SpeakerSnapshot

    var body: some View {
        Label {
            Text(snapshot.volume, format: .number).monospacedDigit()
        } icon: {
            Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .font(.caption.weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.muted ? Text("Muted, volume \(snapshot.volume)") : Text("Volume \(snapshot.volume)"))
    }
}

private struct SmallView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                ArtworkTile(entry: entry)
                    .frame(width: 58, height: 58)
                Spacer(minLength: 0)
                if let snapshot = entry.snapshot, entry.status == .on {
                    VolumeLabel(snapshot: snapshot)
                }
            }
            Spacer(minLength: 0)
            Caption(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 14) {
            ArtworkTile(entry: entry)
            VStack(alignment: .leading, spacing: 0) {
                if let name = entry.snapshot?.name, entry.status == .on, entry.snapshot?.title != nil {
                    Text(verbatim: name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.bottom, 2)
                }
                Caption(entry: entry, titleLines: 2)
                Spacer(minLength: 6)
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var controls: some View {
        switch entry.status {
        case .on:
            if let snapshot = entry.snapshot {
                HStack(spacing: 8) {
                    VolumeBar(volume: snapshot.volume, ceiling: snapshot.ceiling, muted: snapshot.muted)
                    Text(snapshot.volume, format: .number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
                .padding(.bottom, 8)
                HStack(spacing: 8) {
                    Button(intent: WidgetVolumeDownIntent()) {
                        Image(systemName: "minus").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Volume Down")
                    Button(intent: WidgetSetMuteIntent(muted: !snapshot.muted)) {
                        Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WidgetButtonStyle(isActive: snapshot.muted))
                    .accessibilityLabel(snapshot.muted ? "Unmute" : "Mute")
                    Button(intent: WidgetVolumeUpIntent()) {
                        Image(systemName: "plus").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Volume Up")
                }
                .buttonStyle(WidgetButtonStyle())
            }
        case .standby:
            Button(intent: WidgetSetPowerIntent(on: true)) {
                Label("Turn On", systemImage: "power").frame(maxWidth: .infinity)
            }
            .buttonStyle(WidgetButtonStyle())
        case .offline, .noSpeaker:
            EmptyView()
        }
    }
}

/// Round-cornered buttons on the teal; an active one (Mute while muted) is filled saffron,
/// or, where the widget draws in one colour, outlined.
private struct WidgetButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ActiveFill(isActive: isActive, isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct ActiveFill<Label: View>: View {
        let isActive: Bool
        let isPressed: Bool
        @ViewBuilder let label: Label

        @Environment(\.widgetRenderingMode) private var renderingMode

        var body: some View {
            let saffron = isActive && renderingMode == .fullColor
            label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(saffron ? AnyShapeStyle(.black.opacity(0.8)) : AnyShapeStyle(.foreground))
                .frame(height: 30)
                .background {
                    Capsule()
                        .fill(saffron ? AnyShapeStyle(Color("AccentColor")) : AnyShapeStyle(.white.opacity(isPressed ? 0.28 : 0.16)))
                        .opacity(saffron && isPressed ? 0.8 : 1)
                }
                .overlay {
                    // One colour (tinted, clear, StandBy): a fill would wash out the glyph, so an outline.
                    if isActive && !saffron {
                        Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
    }
}

/// The volume as a bar out of 100, with a tick at the volume limit when it is on.
private struct VolumeBar: View {
    let volume: Int
    let ceiling: Int
    let muted: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule()
                    .fill(muted ? AnyShapeStyle(.white.opacity(0.45)) : AnyShapeStyle(Color("AccentColor")))
                    .frame(width: max(6, width * CGFloat(min(volume, 100)) / 100))
                    .widgetAccentable()
                if ceiling < 100 {
                    Rectangle()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: 10)
                        .offset(x: width * CGFloat(ceiling) / 100 - 1)
                }
            }
            .frame(height: 6)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(muted ? "Muted, volume \(volume)" : "Volume \(volume)"))
        .accessibilityValue(ceiling < 100 ? Text("Limit \(ceiling)") : Text(verbatim: ""))
    }
}

// MARK: Lock Screen

private struct CircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let snapshot = entry.snapshot, entry.status == .on {
            Gauge(value: Double(snapshot.volume), in: 0...100) {
                Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            } currentValueLabel: {
                Text(snapshot.volume, format: .number)
            }
            .gaugeStyle(.accessoryCircular)
            .accessibilityLabel(snapshot.muted ? Text("Muted, volume \(snapshot.volume)") : Text("Volume \(snapshot.volume)"))
        } else {
            ZStack {
                AccessoryWidgetBackground()
                SpeakerGlyphShape(style: entry.status == .offline ? .offline : .standby)
                    .fill(style: FillStyle(eoFill: true))
                    .aspectRatio(SpeakerGlyphShape.aspectRatio, contentMode: .fit)
                    .padding(12)
            }
            .accessibilityLabel(entry.status == .offline ? "Can't reach the speaker" : "Standby")
        }
    }
}

private struct RectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let snapshot = entry.snapshot {
                Text(verbatim: snapshot.name).font(.headline).lineLimit(1)
                switch entry.status {
                case .on:
                    Text(verbatim: snapshot.title ?? snapshot.input?.shortName ?? "On").lineLimit(1)
                    VolumeLabel(snapshot: snapshot)
                case .standby: Text("Standby")
                default: Text("Can't Reach")
                }
            } else {
                Text("Speakeasy").font(.headline)
                Text("Open the app to find your speaker.").lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let snapshot = entry.snapshot, entry.status == .on {
            Label {
                Text(verbatim: "\(snapshot.title ?? snapshot.name) · \(snapshot.volume)")
            } icon: {
                Image(systemName: snapshot.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
        } else if let snapshot = entry.snapshot {
            Label {
                Text(verbatim: snapshot.name)
            } icon: {
                Image(systemName: "powersleep")
            }
        } else {
            Text("Speakeasy")
        }
    }
}

extension SpeakerSnapshot {
    /// Sample content for the widget gallery.
    static let preview = SpeakerSnapshot(
        name: "Living Room", isOn: true, source: Source.wifi.rawValue, volume: 24, ceiling: 100, muted: false,
        title: "Song Title", artist: "Artist", playback: PlayerState.Playback.playing.rawValue)
}
