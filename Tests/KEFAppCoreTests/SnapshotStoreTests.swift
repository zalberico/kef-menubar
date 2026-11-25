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
            let art = try #require(store.readArtwork())
            #expect(max(art.width, art.height) == 300)
            #expect(art.width == 2 * art.height)
            #expect(store.read()?.artworkKey == "abc123")
        }
    }

    @Test func snapshotWithoutArtworkDropsTheStoredArt() throws {
        try withStore { store in
            try store.write(Self.sample, artwork: Self.image(width: 64, height: 64))
            try store.write(Self.sample, artwork: nil)
            #expect(store.readArtwork() == nil)
            #expect(store.read()?.artworkKey == nil)
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
