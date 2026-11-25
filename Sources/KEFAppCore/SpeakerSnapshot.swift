import CoreGraphics
import Foundation
import ImageIO
import KEFKit

/// What the widgets show, written by the app (and by the intents after a change) to the
/// App Group container. Widgets never fetch artwork themselves.
public struct SpeakerSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var isOn: Bool
    /// `Source.rawValue`, `nil` if unknown.
    public var source: String?
    public var volume: Int
    /// The highest volume allowed (the speaker's limit when on, else 100).
    public var ceiling: Int
    public var muted: Bool
    public var title: String?
    public var artist: String?
    /// `PlayerState.Playback.rawValue`.
    public var playback: String
    /// Key of the artwork stored next to the snapshot (see ``SpeakerModel/artworkKey``),
    /// `nil` when there is none.
    public var artworkKey: String?
    public var updatedAt: Date

    public init(name: String, isOn: Bool, source: String?, volume: Int, ceiling: Int, muted: Bool,
                title: String? = nil, artist: String? = nil, playback: String = PlayerState.Playback.stopped.rawValue,
                artworkKey: String? = nil, updatedAt: Date = Date()) {
        self.name = name
        self.isOn = isOn
        self.source = source
        self.volume = volume
        self.ceiling = ceiling
        self.muted = muted
        self.title = title
        self.artist = artist
        self.playback = playback
        self.artworkKey = artworkKey
        self.updatedAt = updatedAt
    }

    public var input: Source? { source.flatMap(Source.init(rawValue:)) }
    public var isPlaying: Bool { playback == PlayerState.Playback.playing.rawValue }
}

extension SpeakerModel {
    /// The live state as a snapshot, `nil` until the speaker has been reached once.
    public func snapshot(at date: Date = Date()) -> SpeakerSnapshot? {
        guard hasCachedState else { return nil }
        let track = player.hasMetadata ? player.track : nil
        return SpeakerSnapshot(
            name: name, isOn: source != nil && source != .standby, source: source?.rawValue,
            volume: volume, ceiling: volumeCeiling, muted: muted,
            title: track?.title, artist: track?.artist, playback: player.playback.rawValue,
            artworkKey: artworkKey, updatedAt: date)
    }
}

/// Reads and writes `snapshot.json` and `artwork.jpg` in a directory (the App Group
/// container on iOS). Writes are atomic, so a widget never reads half a file.
public struct SnapshotStore: Sendable {
    public let containerURL: URL

    public init(containerURL: URL) {
        self.containerURL = containerURL
    }

    public var snapshotURL: URL { containerURL.appendingPathComponent("snapshot.json") }
    public var artworkURL: URL { containerURL.appendingPathComponent("artwork.jpg") }

    public func write(_ snapshot: SpeakerSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    /// Write a snapshot with its artwork: the image when there is one, else the stored
    /// artwork is removed. The artwork goes first, so a snapshot never points at missing art.
    public func write(_ snapshot: SpeakerSnapshot, artwork: CGImage?) throws {
        var snapshot = snapshot
        if let artwork, snapshot.artworkKey != nil {
            try writeArtwork(artwork)
        } else {
            removeArtwork()
            snapshot.artworkKey = nil
        }
        try write(snapshot)
    }

    /// Write a snapshot read without artwork (by an intent): its `artworkKey` is kept only
    /// if the stored artwork is that one, so the widget never shows another track's art.
    public func update(with fresh: SpeakerSnapshot) throws {
        var snapshot = fresh
        if snapshot.artworkKey != read()?.artworkKey { snapshot.artworkKey = nil }
        try write(snapshot)
    }

    public func read() -> SpeakerSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SpeakerSnapshot.self, from: data)
    }

    /// Store `image` as a small JPEG (at most `maxPixelSize` on its longest side).
    public func writeArtwork(_ image: CGImage, maxPixelSize: Int = 300, quality: Double = 0.8) throws {
        guard let data = Self.jpegData(image, maxPixelSize: maxPixelSize, quality: quality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try data.write(to: artworkURL, options: .atomic)
    }

    public func readArtwork() -> CGImage? {
        guard let data = try? Data(contentsOf: artworkURL) else { return nil }
        return SpeakerModel.decodeImage(data, maxPixelSize: 600)
    }

    public func removeArtwork() {
        try? FileManager.default.removeItem(at: artworkURL)
    }

    static func jpegData(_ image: CGImage, maxPixelSize: Int, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationImageMaxPixelSize: maxPixelSize,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
