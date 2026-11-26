import Foundation
import KEFKit

/// One fresh read of the speaker for everything that asks at once: opening Control Center
/// asks every control's value provider together, and the widget's timeline may ask too.
/// A snapshot younger than `maxAge` is served as it is; otherwise one read runs and every
/// caller waits for it. A read attempted within `maxAge` (by any process sharing the
/// store) isn't repeated, and a read that fails serves the last stored snapshot.
public actor SnapshotReader {
    public struct Reading: Sendable, Equatable {
        /// The fresh snapshot, or the last stored one; `nil` before the speaker was ever read.
        public var snapshot: SpeakerSnapshot?
        /// `snapshot` was just read (or is younger than `maxAge`).
        public var isFresh: Bool
        /// This read failed: the speaker couldn't be reached just now.
        public var readFailed: Bool

        public init(snapshot: SpeakerSnapshot?, isFresh: Bool, readFailed: Bool = false) {
            self.snapshot = snapshot
            self.isFresh = isFresh
            self.readFailed = readFailed
        }
    }

    public let store: SnapshotStore
    public let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: Task<Reading, Never>?

    public init(store: SnapshotStore, maxAge: TimeInterval = 5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.maxAge = maxAge
        self.now = now
    }

    /// The current snapshot, reading the speaker with `read` at most once for callers that
    /// overlap. The result is written to the store, unless the store was written while the
    /// read ran (an intent's outcome, the app): that is newer than what the read began
    /// with, so it is kept and served instead. A widget or control reload after an intent
    /// can join a read that started before it and still gets the intent's change.
    public func current(read: @escaping @Sendable () async throws -> SpeakerSnapshot) async -> Reading {
        if let inFlight { return await inFlight.value }
        let stored = store.read()
        let date = now()
        if let stored, date.timeIntervalSince(stored.updatedAt) < maxAge {
            return Reading(snapshot: stored, isFresh: true)
        }
        if let attempt = store.lastReadAttempt(), abs(date.timeIntervalSince(attempt)) < maxAge {
            return Reading(snapshot: stored, isFresh: false)
        }
        let revision = store.revision()
        store.markReadAttempt(at: date)
        let store = store
        let task = Task<Reading, Never> {
            do {
                let fresh = try await read()
                if store.revision() == revision { try? store.update(with: fresh) }
                return Reading(snapshot: store.read() ?? fresh, isFresh: true)
            } catch {
                return Reading(snapshot: store.read(), isFresh: false, readFailed: true)
            }
        }
        inFlight = task
        let reading = await task.value
        inFlight = nil
        return reading
    }
}

extension SnapshotStore {
    private var readAttemptURL: URL { containerURL.appendingPathComponent("read-attempt") }
    var revisionURL: URL { containerURL.appendingPathComponent("snapshot-revision") }

    /// Changes with every write of the snapshot (any process), so a read can tell whether
    /// the store was written while it ran. `nil` before the first write.
    public func revision() -> String? {
        guard let data = try? Data(contentsOf: revisionURL) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Mark the snapshot as about to change. Before the write, so a read that checks between
    /// the two already sees the change coming and doesn't overwrite it.
    func bumpRevision() throws {
        try Data(UUID().uuidString.utf8).write(to: revisionURL, options: .atomic)
    }

    /// When a fresh read last started (any process), so overlapping askers share it.
    public func lastReadAttempt() -> Date? {
        guard let data = try? Data(contentsOf: readAttemptURL),
              let seconds = Double(String(decoding: data, as: UTF8.self)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func markReadAttempt(at date: Date) {
        try? FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        try? Data(String(date.timeIntervalSince1970).utf8).write(to: readAttemptURL, options: .atomic)
    }

    /// Fold a command's outcome into the stored snapshot, so widgets and controls show the
    /// change at once. `updatedAt` is kept: the rest of the snapshot is no newer, so the
    /// next widget or control refresh still reads the speaker. Nothing is written when no
    /// snapshot is stored yet.
    public func apply(_ change: (inout SpeakerSnapshot) -> Void) {
        guard var snapshot = read() else { return }
        change(&snapshot)
        try? update(with: snapshot)
    }
}

extension SpeakerSnapshot {
    public mutating func apply(_ outcome: VolumeOutcome) {
        volume = outcome.applied
        ceiling = outcome.ceiling
        muted = outcome.muted
        isOn = true
    }

    public mutating func apply(_ outcome: MuteOutcome) {
        muted = outcome.muted
    }

    public mutating func apply(_ outcome: PowerOutcome) {
        isOn = outcome.isOn
        source = outcome.isOn ? outcome.source?.rawValue ?? source : Source.standby.rawValue
        if !outcome.isOn { clearTrack() }
    }

    public mutating func apply(_ outcome: InputOutcome) {
        isOn = true
        if source != outcome.source.rawValue {
            source = outcome.source.rawValue
            clearTrack()
        }
    }

    /// Play / pause flips the playback state (when it was sent); a skip leaves the track to
    /// the next read.
    public mutating func apply(_ outcome: PlaybackOutcome) {
        if outcome.command == .pause, outcome.wrote {
            playback = (outcome.wasPlaying ? PlayerState.Playback.paused : .playing).rawValue
        }
    }

    private mutating func clearTrack() {
        title = nil
        artist = nil
        artworkKey = nil
        playback = PlayerState.Playback.stopped.rawValue
    }
}
