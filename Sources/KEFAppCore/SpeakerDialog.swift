import KEFKit

/// What Siri says and Shortcuts shows after a ``SpeakerCommand``: one short sentence per
/// outcome, using the speaker's name, and failure replies that tell the causes apart (no
/// speaker chosen, Local Network access off, the speaker unreachable, another speaker
/// answering, a change that may or may not have applied).
///
/// Failure replies never include the underlying error's text: it can carry the speaker's
/// address.
public struct SpeakerDialog: Sendable, Equatable {
    /// The app's name, for "Choose a speaker in Speakeasy first."
    public var appName: String
    /// The speaker's name; "your speaker" stands in when it isn't known yet.
    public var speakerName: String

    public init(appName: String, speakerName: String) {
        self.appName = appName
        let trimmed = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.speakerName = trimmed.isEmpty ? Self.fallbackName : trimmed
    }

    static let fallbackName = "your speaker"

    /// The name at the start of a sentence ("Your speaker is muted.").
    private var subject: String {
        speakerName == Self.fallbackName ? "Your speaker" : speakerName
    }

    private func name(_ outcomeName: String) -> String {
        SpeakerDialog(appName: appName, speakerName: outcomeName.isEmpty ? speakerName : outcomeName).subject
    }

    // MARK: Volume

    /// Set Volume: "Living Room is at 30." / "Living Room is at 40, its volume limit."
    public func setVolume(_ outcome: VolumeOutcome) -> String {
        let who = name(outcome.speakerName)
        var line = if outcome.limited, outcome.atCeiling, outcome.requested >= outcome.ceiling {
            "\(who) is at \(outcome.applied), its volume limit."
        } else {
            "\(who) is at \(outcome.applied)."
        }
        if outcome.muted { line += " It's muted." }
        return line
    }

    /// Volume Up / Down: "Volume 26." / "Unmuted. Volume 26." /
    /// "Already at the volume limit, 40." / "Already at 0."
    public func step(_ outcome: VolumeOutcome, direction: SpeakerCommand.Direction) -> String {
        let prefix = outcome.unmuted ? "Unmuted. " : ""
        let unchanged = outcome.applied == outcome.previous
        var line: String
        switch direction {
        case .up where unchanged && outcome.atCeiling:
            line = outcome.limited ? "Already at the volume limit, \(outcome.applied)." : "Already at the maximum, \(outcome.applied)."
        case .up where outcome.limited && outcome.atCeiling:
            line = "Volume \(outcome.applied), the volume limit."
        case .down where unchanged && outcome.applied == 0:
            line = "Already at 0."
        default:
            line = "Volume \(outcome.applied)."
        }
        if outcome.muted { line += " Still muted." }
        return prefix + line
    }

    // MARK: Mute, power, inputs

    /// "Living Room is muted." / "Living Room is unmuted."
    public func mute(_ outcome: MuteOutcome) -> String {
        "\(name(outcome.speakerName)) is \(outcome.muted ? "muted" : "unmuted")."
    }

    /// "Living Room is on, on Wi-Fi." / "Living Room is in standby."
    public func power(_ outcome: PowerOutcome) -> String {
        let who = name(outcome.speakerName)
        guard outcome.isOn else { return "\(who) is in standby." }
        guard let source = outcome.source, source != .standby else { return "\(who) is on." }
        return "\(who) is on, on \(source.displayName)."
    }

    /// "Switched to TV." / "Already on TV." (switching an input wakes the speaker:
    /// "Living Room is on, on TV.")
    public func input(_ outcome: InputOutcome) -> String {
        if !outcome.wrote { return "Already on \(outcome.source.displayName)." }
        if !outcome.wasOn { return "\(name(outcome.speakerName)) is on, on \(outcome.source.displayName)." }
        return "Switched to \(outcome.source.displayName)."
    }

    // MARK: Playback

    /// "Paused." / "Playing." / "Skipped." / "Playing the previous track."
    public func playback(_ outcome: PlaybackOutcome) -> String {
        switch outcome.command {
        case .pause: outcome.wasPlaying ? "Paused." : "Playing."
        case .stop: "Stopped."
        case .next: "Skipped."
        case .previous: "Playing the previous track."
        }
    }

    // MARK: Failures

    /// The reply for an error thrown by ``SpeakerCommand`` (or its `connect`). Pass
    /// `localNetworkDenied` when the system reports Local Network access as turned off: it
    /// explains a speaker that couldn't be reached. `nil` for a cancellation, which has no
    /// reply.
    public func failure(_ error: any Error, localNetworkDenied: Bool = false) -> String? {
        if error is CancellationError { return nil }
        guard let error = error as? SpeakerCommandError else {
            if let error = error as? KEFError {
                return failure(SpeakerCommand.map(error, writeSent: false), localNetworkDenied: localNetworkDenied)
            }
            return "Something went wrong with \(speakerName). Try again in \(appName)."
        }
        switch error {
        case .noSpeaker:
            return "Choose a speaker in \(appName) first."
        case .unreachable, .timedOut(writeSent: false):
            if localNetworkDenied { return localNetworkReply }
            return "I couldn't reach \(speakerName). Check it's on and on the same Wi-Fi."
        case .timedOut(writeSent: true):
            return "\(subject) didn't confirm in time; it may have changed."
        case .differentSpeaker:
            return "A different speaker answered instead of \(speakerName). Open \(appName) to find it again."
        case .unsupportedInput(let source):
            if source == .standby { return "To put \(speakerName) in standby, turn it off instead." }
            return "\(subject) doesn't have \(Self.article(source.displayName)) \(source.displayName.lowercasedInput) input."
        case .controlUnavailable(let command):
            let action = switch command {
            case .pause: "play or pause"
            case .stop: "stop"
            case .next: "skip"
            case .previous: "go back"
            }
            return "\(subject) can't \(action) on this input."
        case .failed:
            return "\(subject) couldn't do that. Try again in \(appName)."
        }
    }

    /// The reply when Local Network access is off.
    public var localNetworkReply: String {
        "\(appName) needs Local Network access. Open \(appName) to allow it."
    }

    /// "a" or "an" before an input's name, by how it is said ("an optical", "a USB").
    static func article(_ word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        if word == "USB" { return "a" }
        return "aeio".contains(first) ? "an" : "a"
    }
}

private extension String {
    /// "Coaxial" → "coaxial", keeping names that are acronyms or brands as they are.
    var lowercasedInput: String {
        switch self {
        case "USB", "TV", "Wi-Fi", "Bluetooth": self
        default: lowercased()
        }
    }
}
