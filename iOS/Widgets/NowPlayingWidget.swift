import KEFAppCore
import KEFKit
import SwiftUI
import WidgetKit

/// Placeholder now-playing widget: shows the snapshot the app saved. Display only.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Now Playing")
        .description("Your speaker's track and volume.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: SpeakerSnapshot?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let stored = AppGroup.snapshotStore?.read()
        completion(NowPlayingEntry(date: .now, snapshot: stored ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // The app reloads the timeline whenever what it shows changes.
        let entry = NowPlayingEntry(date: .now, snapshot: AppGroup.snapshotStore?.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

struct NowPlayingView: View {
    let snapshot: SpeakerSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot {
                Text(verbatim: snapshot.name)
                    .font(.headline)
                    .lineLimit(1)
                if let title = snapshot.title {
                    Text(verbatim: title)
                        .font(.subheadline)
                        .lineLimit(2)
                    if let artist = snapshot.artist {
                        Text(verbatim: artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(verbatim: snapshot.isOn ? snapshot.input?.displayName ?? "On" : "Standby")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if snapshot.muted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.caption)
                } else {
                    Label {
                        Text(snapshot.volume, format: .number)
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .font(.caption)
                    .accessibilityLabel("Volume \(snapshot.volume)")
                }
            } else {
                Text("Speakeasy")
                    .font(.headline)
                Text("Open the app to find your speaker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

extension SpeakerSnapshot {
    /// Sample content for the widget gallery.
    static let preview = SpeakerSnapshot(
        name: "Living Room", isOn: true, source: Source.wifi.rawValue, volume: 24, ceiling: 100, muted: false,
        title: "Song Title", artist: "Artist", playback: PlayerState.Playback.playing.rawValue)
}
