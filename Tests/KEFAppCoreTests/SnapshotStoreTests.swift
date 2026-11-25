import CoreGraphics
import Foundation
import Testing
@testable import KEFAppCore

struct SnapshotStoreTests {
    func withStore(_ body: (SnapshotStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KEFAppCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(SnapshotStore(containerURL: dir))
    }

    static let sample = SpeakerSnapshot(
        name: "Living Room", isOn: true, source: "wifi", volume: 24, ceiling: 40, muted: false,
        title: "A Song", artist: "Someone", playback: "playing", artworkKey: "abc123",
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func snapshotRoundTrips() throws {
        try withStore { store in
            #expect(store.read() == nil)
            try store.write(Self.sample)
            #expect(store.read() == Self.sample)
            #expect(store.read()?.input == .wifi)
            #expect(store.read()?.isPlaying == true)
        }
    }

    @Test func artworkIsStoredSmall() throws {
        try withStore { store in
            try store.write(Self.sample, artwork: Self.image(width: 800, height: 400))
            let art = try #require(store.readArtwork(key: store.read()?.artworkKey))
            #expect(max(art.width, art.height) == 300)
            #expect(art.width == 2 * art.height)
            #expect(store.read()?.artworkKey == "abc123")
        }
    }

    @Test func snapshotWithoutArtworkDropsTheStoredArt() throws {
        try withStore { store in
            try store.write(Self.sample, artwork: Self.image(width: 64, height: 64))
            try store.write(Self.sample, artwork: nil)
            #expect(store.readArtwork(key: "abc123") == nil)
            #expect(store.read()?.artworkKey == nil)
            #expect(Self.artworkFiles(store).isEmpty)
        }
    }

    @Test func updateKeepsTheArtworkKeyOnlyForTheSameArt() throws {
        try withStore { store in
            try store.write(Self.sample, artwork: Self.image(width: 64, height: 64))
            var fresh = Self.sample
            fresh.volume = 26
            try store.update(with: fresh)
            #expect(store.read()?.artworkKey == "abc123")
            #expect(store.read()?.volume == 26)
            fresh.artworkKey = "another-track"
            try store.update(with: fresh)
            #expect(store.read()?.artworkKey == nil)
        }
    }

    static func artworkFiles(_ store: SnapshotStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.containerURL.path)) ?? [])
            .filter { $0.hasPrefix("artwork") }.sorted()
    }

    @Test func artworkIsReadOnlyForItsKey() throws {
        try withStore { store in
            try store.write(Self.sample, artwork: Self.image(width: 64, height: 64))
            #expect(store.readArtwork(key: "abc123") != nil)
            // Text from one track and art from another read as "no art".
            #expect(store.readArtwork(key: "another-track") == nil)
            #expect(store.readArtwork(key: nil) == nil)
            var next = Self.sample
            next.artworkKey = "def456"
            try store.write(next, artwork: Self.image(width: 64, height: 64))
            #expect(store.readArtwork(key: "def456") != nil)
            #expect(store.readArtwork(key: "abc123") == nil)  // the older art is removed
            #expect(Self.artworkFiles(store) == ["artwork-def456.jpg"])
        }
    }

    @Test func artworkKeysMustBePlainNames() throws {
        try withStore { store in
            #expect(store.artworkURL(for: "abc-123") != nil)
            #expect(store.artworkURL(for: "../escape") == nil)
            #expect(store.artworkURL(for: "a/b") == nil)
            #expect(store.artworkURL(for: "") == nil)
            var odd = Self.sample
            odd.artworkKey = "../escape"
            try store.write(odd, artwork: Self.image(width: 64, height: 64))
            #expect(store.read()?.artworkKey == nil)
            #expect(Self.artworkFiles(store).isEmpty)
        }
    }

    @Test func decodeDownsamples() throws {
        let data = try #require(SnapshotStore.jpegData(Self.image(width: 1200, height: 900), maxPixelSize: 1200, quality: 0.9))
        let image = try #require(SpeakerModel.decodeImage(data, maxPixelSize: 600))
        #expect(image.width == 600 && image.height == 450)
        #expect(SpeakerModel.decodeImage(Data("not an image".utf8), maxPixelSize: 600) == nil)
    }

    @Test func artworkKeyIsStable() {
        let url = URL(string: "https://example.invalid/art/1.jpg")!
        #expect(SpeakerModel.artworkKey(for: url) == SpeakerModel.artworkKey(for: url))
        #expect(SpeakerModel.artworkKey(for: url) != SpeakerModel.artworkKey(for: URL(string: "https://example.invalid/art/2.jpg")!))
    }
}
