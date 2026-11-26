import Foundation
import KEFKit

/// Why a ``SpeakerCommand`` didn't do what was asked. Each case carries what a dialog needs.
public enum SpeakerCommandError: Error, Sendable, Equatable, LocalizedError {
    /// No speaker has been found or entered yet.
    case noSpeaker
    /// In automatic mode, another speaker answered at the chosen speaker's last address.
    case differentSpeaker
    /// The speaker couldn't be reached (nothing was sent).
    case unreachable
    /// The speaker didn't answer in time. With `writeSent`, the change may or may not have
    /// been applied.
    case timedOut(writeSent: Bool)
    /// This speaker model has no such input.
    case unsupportedInput(Source)
    /// The current source doesn't offer this playback control right now.
    case controlUnavailable(PlayerCommand)
    /// The speaker refused the request.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeaker: "No speaker has been set up yet. Open the app to find yours."
        case .differentSpeaker: "A different speaker answered. Open the app to find yours again."
        case .unreachable: "Couldn't reach the speaker."
        case .timedOut(let writeSent):
            writeSent ? "The speaker didn't answer in time. The change may not have applied."
                      : "The speaker didn't answer in time."
        case .unsupportedInput(let source): "This speaker has no \(source.displayName) input."
        case .controlUnavailable: "That isn't available for what's playing."
        case .failed(let message): message
        }
    }
}

/// Result of a volume change.
public struct VolumeOutcome: Sendable, Equatable {
    public var speakerName: String
    /// The volume asked for (for a step: the current volume plus the step), before clamping.
    public var requested: Int
    public var previous: Int
    /// The volume the speaker is at now.
    public var applied: Int
    /// The highest volume allowed (the speaker's limit when on, else 100).
    public var ceiling: Int
    /// The speaker's own volume limit is on.
    public var limited: Bool
    /// `requested` was outside `0...ceiling`.
    public var clamped: Bool
    /// Muted after the command.
    public var muted: Bool
    /// This command unmuted the speaker (a step up while muted).
    public var unmuted: Bool
    /// A volume write was sent.
    public var wrote: Bool

    public var atCeiling: Bool { applied >= ceiling }
}

public struct MuteOutcome: Sendable, Equatable {
    public var speakerName: String
    public var muted: Bool
    public var wrote: Bool
}

public struct PowerOutcome: Sendable, Equatable {
    public var speakerName: String
    public var isOn: Bool
    /// The input it is on (`nil` in standby, or for an input this app doesn't know).
    public var source: Source?
    public var wrote: Bool
}

public struct InputOutcome: Sendable, Equatable {
    public var speakerName: String
    public var source: Source
    /// The speaker was on before (selecting an input wakes it).
    public var wasOn: Bool
    public var wrote: Bool
}

public struct PlaybackOutcome: Sendable, Equatable {
    public var speakerName: String
    public var command: PlayerCommand
    public var wasPlaying: Bool
    /// What a play / pause asked for (`.toggle` for the other commands).
    public var request: PlaybackRequest
    /// The playback state before the command.
    public var previous: PlayerState.Playback
    /// The command was sent; `false` when a play or pause found the speaker already so.
    public var wrote: Bool

    public init(speakerName: String, command: PlayerCommand, wasPlaying: Bool, request: PlaybackRequest = .toggle,
                previous: PlayerState.Playback? = nil, wrote: Bool = true) {
        self.speakerName = speakerName
        self.command = command
        self.wasPlaying = wasPlaying
        self.request = request
        self.previous = previous ?? (wasPlaying ? .playing : .paused)
        self.wrote = wrote
    }
}

/// What a play / pause asks for. The speaker only has a toggle, so `play` and `pause` send
/// it only when the speaker isn't already in that state: "pause" never starts playback.
public enum PlaybackRequest: Sendable, Equatable {
    case toggle, play, pause
}

/// One-shot speaker access for widgets, controls and intents: read what the operation needs,
/// one request at a time, then make the write. Volume follows the app's rules: never above
/// the speaker's volume limit, read fresh each time. Only ``KEFClient`` methods are used, so
/// ``KEFKit/KEFSafety`` always applies. Everything shares one deadline from ``connect(_:timeout:makeClient:)``.
public struct SpeakerCommand: Sendable {
    public enum Direction: Sendable { case up, down }

    public static let defaultTimeout: Duration = .seconds(8)

    /// HTTPS straight away for a speaker known to use it (they never downgrade), else probe.
    public static let defaultClient: @Sendable (String, Bool?) -> KEFClient = { host, secure in
        KEFClient(host: host, mode: secure == true ? .https : .auto)
    }

    public let config: SharedSpeakerConfig
    let client: KEFClient
    let deadline: ContinuousClock.Instant

    /// Prepare commands for the configured speaker (no I/O yet). Throws
    /// ``SpeakerCommandError/noSpeaker`` when there is no address.
    public static func connect(
        _ config: SharedSpeakerConfig,
        timeout: Duration = defaultTimeout,
        makeClient: @Sendable (String, Bool?) -> KEFClient = defaultClient
    ) throws -> SpeakerCommand {
        guard let host = config.host else { throw SpeakerCommandError.noSpeaker }
        return SpeakerCommand(config: config, client: makeClient(host, config.lastIsSecure),
                              deadline: .now + timeout)
    }

    /// Release the connection.
    public func close() async {
        await client.transport.close()
    }

    // MARK: Volume

    /// Set the volume, clamped to `0...ceiling`. The mute state is left as it is.
    public func setVolume(_ requested: Int) async throws -> VolumeOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let (ceiling, limited) = try await readCeiling()
            let current = try await client.volume()
            let muted = try await client.isMuted()
            let target = VolumePolicy.clamp(requested, ceiling: ceiling)
            var wrote = false
            if target != current {
                try await write(tracker) { try await client.setVolume(target) }
                wrote = true
            }
            return VolumeOutcome(
                speakerName: try await speakerName(), requested: requested, previous: current, applied: target,
                ceiling: ceiling, limited: limited, clamped: target != requested, muted: muted,
                unmuted: false, wrote: wrote)
        }
    }

    /// One step (the app's volume step unless `by` is given, kept within 1...10). Like the
    /// app's buttons, a step up unmutes first.
    public func step(_ direction: Direction, by size: Int? = nil) async throws -> VolumeOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let (ceiling, limited) = try await readCeiling()
            let current = try await client.volume()
            let muted = try await client.isMuted()
            let size = min(max(size ?? config.volumeStep, VolumePolicy.stepRange.lowerBound), VolumePolicy.stepRange.upperBound)
            let delta = direction == .up ? size : -size
            let target = VolumePolicy.step(from: current, by: delta, ceiling: ceiling)
            var unmuted = false
            if muted && direction == .up {
                try await write(tracker) { try await client.setMuted(false) }
                unmuted = true
            }
            var wrote = false
            if target != current {
                try await write(tracker) { try await client.setVolume(target) }
                wrote = true
            }
            return VolumeOutcome(
                speakerName: try await speakerName(), requested: current + delta, previous: current, applied: target,
                ceiling: ceiling, limited: limited, clamped: target != current + delta, muted: muted && !unmuted,
                unmuted: unmuted, wrote: wrote)
        }
    }

    public func setMuted(_ muted: Bool) async throws -> MuteOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let current = try await client.isMuted()
            if current != muted {
                try await write(tracker) { try await client.setMuted(muted) }
            }
            return MuteOutcome(speakerName: try await speakerName(), muted: muted, wrote: current != muted)
        }
    }

    // MARK: Power and inputs

    /// Turn on (on the last input used, or the model's first input) or put in standby.
    public func setPower(_ on: Bool) async throws -> PowerOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let current = try await currentSource()
            let isOn = current != .standby
            guard on != isOn else {
                return PowerOutcome(speakerName: try await speakerName(), isOn: isOn, source: on ? current : nil, wrote: false)
            }
            let target = on ? try await wakeSource() : Source.standby
            try await write(tracker) { try await client.setSource(target) }
            return PowerOutcome(speakerName: try await speakerName(), isOn: on, source: on ? target : nil, wrote: true)
        }
    }

    /// Switch to an input this model has (it wakes the speaker). Refuses `standby`; use
    /// ``setPower(_:)`` for that.
    public func select(_ source: Source) async throws -> InputOutcome {
        try await run { tracker in
            guard source != .standby else { throw SpeakerCommandError.unsupportedInput(source) }
            if let code = config.modelCode, !Source.inputs(forModel: code).contains(source) {
                throw SpeakerCommandError.unsupportedInput(source)
            }
            try await verifyIdentity()
            guard try await inputs().contains(source) else { throw SpeakerCommandError.unsupportedInput(source) }
            let current = try await currentSource()
            if current != source {
                try await write(tracker) { try await client.setSource(source) }
            }
            return InputOutcome(speakerName: try await speakerName(), source: source,
                                wasOn: current != .standby, wrote: current != source)
        }
    }

    // MARK: Playback

    /// Play / pause, only when the speaker offers it for what is playing. The speaker's
    /// control is a toggle: `.pause` sends it only while playing and `.play` only while
    /// paused or stopped; otherwise nothing is sent and the outcome says so (`wrote` false).
    public func playPause(_ request: PlaybackRequest = .toggle) async throws -> PlaybackOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let state = try await client.playerState()
            let playingOrStarting = state.playback == .playing || state.playback == .transitioning
            let already = switch request {
            case .toggle: false
            case .play: playingOrStarting
            case .pause: state.playback != .playing
            }
            if !already {
                guard state.canPause else { throw SpeakerCommandError.controlUnavailable(.pause) }
                try await write(tracker) { try await client.control(.pause) }
            }
            return PlaybackOutcome(speakerName: try await speakerName(), command: .pause, wasPlaying: state.isPlaying,
                                   request: request, previous: state.playback, wrote: !already)
        }
    }

    public func next() async throws -> PlaybackOutcome {
        try await control(.next) { $0.canNext }
    }

    public func previous() async throws -> PlaybackOutcome {
        try await control(.previous) { $0.canPrevious }
    }

    private func control(_ command: PlayerCommand, available: @escaping @Sendable (PlayerState) -> Bool) async throws -> PlaybackOutcome {
        try await run { tracker in
            try await verifyIdentity()
            let state = try await client.playerState()
            guard available(state) else { throw SpeakerCommandError.controlUnavailable(command) }
            try await write(tracker) { try await client.control(command) }
            return PlaybackOutcome(speakerName: try await speakerName(), command: command, wasPlaying: state.isPlaying,
                                   previous: state.playback)
        }
    }

    // MARK: Reading

    /// The speaker's state for the widgets (no artwork: the key tells whether stored art matches).
    /// An input this app doesn't know counts as on, as in ``SpeakerModel/snapshot(at:)``.
    public func snapshot() async throws -> SpeakerSnapshot {
        try await run { _ in
            try await verifyIdentity()
            let name = try await client.deviceName()
            let source = try await currentSource()
            let volume = try await client.volume()
            let muted = try await client.isMuted()
            let (ceiling, _) = try await readCeiling()
            let player = try await client.playerState()
            let track = player.hasMetadata ? player.track : nil
            return SpeakerSnapshot(
                name: name, isOn: source != .standby, source: source?.rawValue, volume: volume, ceiling: ceiling,
                muted: muted, title: track?.title, artist: track?.artist, playback: player.playback.rawValue,
                artworkKey: track?.artworkURL.map { SpeakerModel.artworkKey(for: $0) }, updatedAt: Date())
        }
    }

    // MARK: Helpers

    /// Refuse to act on another speaker that took over the chosen one's address.
    private func verifyIdentity() async throws {
        if await SpeakerIdentity.isDifferentSpeaker(client, hostMode: config.hostMode, preferredID: config.preferredSpeakerID) {
            throw SpeakerCommandError.differentSpeaker
        }
        try Task.checkCancellation()
    }

    private func readCeiling() async throws -> (ceiling: Int, limited: Bool) {
        let maximum = try await client.maximumVolume()
        let limited = try await client.isVolumeLimited()
        return (VolumePolicy.ceiling(maximum: maximum, limited: limited), limited)
    }

    /// The current input; `nil` for one this app doesn't know (newer firmware), which is on.
    private func currentSource() async throws -> Source? {
        do {
            return try await client.source()
        } catch KEFError.invalidResponse {
            return nil
        }
    }

    private func inputs() async throws -> [Source] {
        let code: String
        if let known = config.modelCode { code = known } else { code = try await client.modelName() }
        return Source.inputs(forModel: code)
    }

    /// The last input used if this model has it, else its first input.
    private func wakeSource() async throws -> Source {
        let inputs = try await inputs()
        if let last = config.lastInput, inputs.contains(last) { return last }
        return inputs.first ?? .wifi
    }

    private func speakerName() async throws -> String {
        config.lastSpeakerName.isEmpty ? try await client.deviceName() : config.lastSpeakerName
    }

    private func write(_ tracker: WriteTracker, _ body: () async throws -> Void) async throws {
        try Task.checkCancellation()
        // Refused once the deadline has passed, so a time-out's `writeSent` is always right.
        guard tracker.markSent() else { throw CancellationError() }
        try await body()
    }

    /// Run `work` against the deadline. On time-out the work is cancelled and the connection
    /// closed, so nothing more is sent, and the call returns at once.
    private func run<T: Sendable>(_ work: @escaping @Sendable (WriteTracker) async throws -> T) async throws -> T {
        let tracker = WriteTracker()
        let remaining = deadline - .now
        guard remaining > .zero else { throw SpeakerCommandError.timedOut(writeSent: false) }
        let race = Race<T>()
        let client = client
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    race.begin(continuation) {
                        let worker = Task {
                            do { race.finish(.success(try await work(tracker))) } catch { race.finish(.failure(error)) }
                        }
                        let timer = Task {
                            try? await Task.sleep(for: remaining)
                            guard !Task.isCancelled else { return }
                            if race.finish(.failure(SpeakerCommandError.timedOut(writeSent: tracker.expire()))) {
                                worker.cancel()
                                await client.transport.close()
                            }
                        }
                        return [worker, timer]
                    }
                }
            } onCancel: {
                race.finish(.failure(CancellationError()))
            }
        } catch {
            throw Self.map(error, writeSent: tracker.sent)
        }
    }

    static func map(_ error: any Error, writeSent: Bool) -> any Error {
        switch error {
        case is SpeakerCommandError, is CancellationError:
            return error
        case let error as KEFError:
            if error.isConnection { return writeSent ? SpeakerCommandError.timedOut(writeSent: true) : SpeakerCommandError.unreachable }
            return SpeakerCommandError.failed(error.errorDescription ?? "The speaker refused the request.")
        default:
            return SpeakerCommandError.failed(error.localizedDescription)
        }
    }
}

/// Remembers whether a write went out (so a time-out can say "may not have applied").
/// Sending and the deadline are decided under one lock: after ``expire()`` no write starts.
final class WriteTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var wasSent = false
    private var expired = false

    var sent: Bool { lock.withLock { wasSent } }

    /// Record that a write is about to go out; `false` (send nothing) once expired.
    func markSent() -> Bool {
        lock.withLock {
            guard !expired else { return false }
            wasSent = true
            return true
        }
    }

    /// The deadline passed: refuse further writes and return whether one went out.
    func expire() -> Bool {
        lock.withLock {
            expired = true
            return wasSent
        }
    }
}

/// The first of the work, the deadline or a cancellation to finish resumes the caller.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    func begin(_ continuation: CheckedContinuation<T, any Error>, start: () -> [Task<Void, Never>]) {
        let alreadyFinished = lock.withLock {
            if !finished { self.continuation = continuation }
            return finished
        }
        if alreadyFinished { continuation.resume(throwing: CancellationError()); return }
        let started = start()
        let cancelNow = lock.withLock {
            if !finished { tasks = started }
            return finished
        }
        if cancelNow { started.forEach { $0.cancel() } }
    }

    @discardableResult
    func finish(_ result: Result<T, any Error>) -> Bool {
        let taken: (continuation: CheckedContinuation<T, any Error>?, tasks: [Task<Void, Never>])? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        guard let taken else { return false }
        taken.tasks.forEach { $0.cancel() }
        taken.continuation?.resume(with: result)
        return true
    }
}
