import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

struct SnapshotReaderTests {
    static let start = Date(timeIntervalSince1970: 1_700_000_000)

    func withStore(_ body: (SnapshotStore) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KEFAppCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(SnapshotStore(containerURL: dir))
    }

    static func snapshot(volume: Int = 24, at date: Date) -> SpeakerSnapshot {
        SpeakerSnapshot(name: "Living Room", isOn: true, source: "wifi", volume: volume, ceiling: 100, muted: false,
                        title: "A Song", artist: "Someone", playback: "playing", updatedAt: date)
    }

    @Test func overlappingCallersShareOneRead() async throws {
        try await withStore { store in
            let reader = SnapshotReader(store: store, now: { Self.start })
            let reads = Box(0)
            let read: @Sendable () async throws -> SpeakerSnapshot = {
                reads.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(200))
                return Self.snapshot(volume: 31, at: Self.start)
            }
            async let first = reader.current(read: read)
            async let second = reader.current(read: read)
            async let third = reader.current(read: read)
            let readings = await [first, second, third]
            #expect(reads.withLock { $0 } == 1)
            #expect(readings.allSatisfy { $0.isFresh && $0.snapshot?.volume == 31 })
            #expect(store.read()?.volume == 31)
        }
    }

    @Test func aYoungSnapshotIsServedWithoutReading() async throws {
        try await withStore { store in
            try store.write(Self.snapshot(volume: 12, at: Self.start.addingTimeInterval(-2)))
            let reader = SnapshotReader(store: store, now: { Self.start })
            let reading = await reader.current { Issue.record("read the speaker"); throw CancellationError() }
            #expect(reading.isFresh && reading.snapshot?.volume == 12)
        }
    }

    @Test func anOldSnapshotIsReadAgain() async throws {
        try await withStore { store in
            try store.write(Self.snapshot(volume: 12, at: Self.start.addingTimeInterval(-60)))
            let reader = SnapshotReader(store: store, now: { Self.start })
            let reading = await reader.current { Self.snapshot(volume: 20, at: Self.start) }
            #expect(reading.isFresh && reading.snapshot?.volume == 20)
        }
    }

    @Test func offlineFallsBackToTheStoredSnapshot() async throws {
        try await withStore { store in
            try store.write(Self.snapshot(volume: 12, at: Self.start.addingTimeInterval(-60)))
            let reader = SnapshotReader(store: store, now: { Self.start })
            let reading = await reader.current { throw SpeakerCommandError.unreachable }
            #expect(!reading.isFresh && reading.readFailed && reading.snapshot?.volume == 12)
            // Nothing stored at all: no snapshot, not fresh.
            try FileManager.default.removeItem(at: store.snapshotURL)
            let later = SnapshotReader(store: store, now: { Self.start.addingTimeInterval(30) })
            let empty = await later.current { throw SpeakerCommandError.unreachable }
            #expect(empty == SnapshotReader.Reading(snapshot: nil, isFresh: false, readFailed: true))
        }
    }

    @Test func aRecentAttemptElsewhereIsNotRepeated() async throws {
        try await withStore { store in
            try store.write(Self.snapshot(volume: 12, at: Self.start.addingTimeInterval(-60)))
            // Another process (the widget, a control) started a read a second ago.
            store.markReadAttempt(at: Self.start.addingTimeInterval(-1))
            let reader = SnapshotReader(store: store, now: { Self.start })
            let reading = await reader.current { Issue.record("read the speaker"); throw CancellationError() }
            #expect(!reading.isFresh && !reading.readFailed && reading.snapshot?.volume == 12)
            // Once it is older than maxAge, a new read runs.
            let later = SnapshotReader(store: store, now: { Self.start.addingTimeInterval(10) })
            let fresh = await later.current { Self.snapshot(volume: 22, at: Self.start.addingTimeInterval(10)) }
            #expect(fresh.isFresh && fresh.snapshot?.volume == 22)
        }
    }

    @Test func aFreshReadKeepsArtworkOnlyWhenItIsStored() async throws {
        try await withStore { store in
            let reader = SnapshotReader(store: store, now: { Self.start })
            var withArt = Self.snapshot(at: Self.start)
            withArt.artworkKey = "abc123"
            let snapshot = withArt
            let reading = await reader.current { snapshot }
            #expect(reading.snapshot?.artworkKey == nil)  // no artwork file for that key
        }
    }

    @Test func anOutcomeFoldedInDuringAReadIsKept() async throws {
        try await withStore { store in
            try store.write(Self.snapshot(volume: 12, at: Self.start.addingTimeInterval(-60)))
            let reader = SnapshotReader(store: store, now: { Self.start })
            let (started, startedGo) = AsyncStream.makeStream(of: Void.self)
            let (proceed, proceedGo) = AsyncStream.makeStream(of: Void.self)
            // The read began before the mute was sent, so it still sees the speaker unmuted.
            async let reading = reader.current {
                startedGo.yield()
                for await _ in proceed { break }
                return Self.snapshot(volume: 12, at: Self.start)
            }
            for await _ in started { break }
            store.apply { $0.apply(MuteOutcome(speakerName: "Living Room", muted: true, wrote: true)) }
            // A reload after the intent joins the read that is still running.
            async let joined = reader.current { Issue.record("read the speaker again"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(50))
            proceedGo.yield()
            let (first, second) = await (reading, joined)
            #expect(store.read()?.muted == true)
            #expect(first.snapshot?.muted == true && second.snapshot?.muted == true)
        }
    }

    @Test func everyWriteChangesTheRevision() async throws {
        try await withStore { store in
            #expect(store.revision() == nil)
            try store.write(Self.snapshot(at: Self.start))
            let first = try #require(store.revision())
            store.apply { $0.muted = true }
            let second = try #require(store.revision())
            try store.update(with: Self.snapshot(at: Self.start))
            #expect(first != second && store.revision() != second)
        }
    }

    // MARK: Folding outcomes into the snapshot

    @Test func outcomesUpdateTheStoredSnapshotButNotItsAge() async throws {
        try await withStore { store in
            let old = Self.start.addingTimeInterval(-600)
            try store.write(Self.snapshot(at: old))
            store.apply {
                $0.apply(VolumeOutcome(speakerName: "Living Room", requested: 30, previous: 24, applied: 30, ceiling: 40,
                                       limited: true, clamped: false, muted: false, unmuted: true, wrote: true))
            }
            var stored = try #require(store.read())
            #expect(stored.volume == 30 && stored.ceiling == 40 && !stored.muted && stored.updatedAt == old)

            store.apply { $0.apply(MuteOutcome(speakerName: "Living Room", muted: true, wrote: true)) }
            #expect(store.read()?.muted == true)

            store.apply { $0.apply(PlaybackOutcome(speakerName: "Living Room", command: .pause, wasPlaying: true)) }
            #expect(store.read()?.playback == "paused")
            // A pause that found it paused already sends nothing and changes nothing.
            store.apply {
                $0.apply(PlaybackOutcome(speakerName: "Living Room", command: .pause, wasPlaying: false, request: .pause,
                                         previous: .paused, wrote: false))
            }
            #expect(store.read()?.playback == "paused")
            store.apply { $0.apply(PlaybackOutcome(speakerName: "Living Room", command: .next, wasPlaying: false)) }
            #expect(store.read()?.playback == "paused" && store.read()?.title == "A Song")

            store.apply { $0.apply(InputOutcome(speakerName: "Living Room", source: .tv, wasOn: true, wrote: true)) }
            stored = try #require(store.read())
            #expect(stored.source == "tv" && stored.isOn && stored.title == nil && stored.playback == "stopped")

            store.apply { $0.apply(PowerOutcome(speakerName: "Living Room", isOn: false, source: nil, wrote: true)) }
            stored = try #require(store.read())
            #expect(!stored.isOn && stored.source == "standby")

            store.apply { $0.apply(PowerOutcome(speakerName: "Living Room", isOn: true, source: .usb, wrote: true)) }
            stored = try #require(store.read())
            #expect(stored.isOn && stored.source == "usb" && stored.updatedAt == old)
        }
    }

    @Test func outcomesNeedAStoredSnapshot() async throws {
        try await withStore { store in
            store.apply { $0.apply(MuteOutcome(speakerName: "Living Room", muted: true, wrote: true)) }
            #expect(store.read() == nil)
        }
    }
}
