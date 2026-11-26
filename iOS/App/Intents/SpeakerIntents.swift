import AppIntents
import KEFAppCore
import KEFKit

// The speaker's intents for Siri, Shortcuts and Spotlight. Each runs in the background,
// reaches the speaker directly with one `SpeakerCommand` and answers with one short
// sentence. None touches firmware, network setup or the volume limit: those stay in the app.
//
// App target only. The widget's buttons and the controls use their own hidden copies in
// the widget extension (Widgets/Intents), so they run there; these would run in the
// extension too if it had them, and App Shortcuts can't run in a widget extension.
//
// The type names are saved in people's shortcuts: never rename them.

// MARK: Volume

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Speaker Volume"
    static let description = IntentDescription(
        "Sets your speaker's volume. It never goes above the volume limit set on the speaker.",
        categoryName: "Volume")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Volume", description: "From 0 to 100.", inclusiveRange: (0, 100),
               requestValueDialog: "What volume?")
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set the speaker's volume to \(\.$level)")
    }

    init() {}

    init(level: Int) {
        self.level = level
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let result = try await SpeakerActions.setVolume(level)
        return .result(value: result.outcome.applied, dialog: "\(result.reply)")
    }
}

struct VolumeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Up"
    static let description = IntentDescription(
        "Turns your speaker up by one step (the step set in the app), unmuting it first. It never goes above the volume limit.",
        categoryName: "Volume")
    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("Turn the speaker's volume up")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let result = try await SpeakerActions.step(.up)
        return .result(value: result.outcome.applied, dialog: "\(result.reply)")
    }
}

struct VolumeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Down"
    static let description = IntentDescription(
        "Turns your speaker down by one step (the step set in the app).", categoryName: "Volume")
    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("Turn the speaker's volume down")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let result = try await SpeakerActions.step(.down)
        return .result(value: result.outcome.applied, dialog: "\(result.reply)")
    }
}

/// Mute or unmute; a `SetValueIntent` so it can back the Mute control's toggle.
struct SetMuteIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Speaker"
    static let description = IntentDescription("Mutes or unmutes your speaker.", categoryName: "Volume")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Muted", displayName: Bool.IntentDisplayName(true: "Mute", false: "Unmute"))
    var value: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$value) the speaker")
    }

    init() {}

    init(muted: Bool) {
        value = muted
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.setMuted(value)
        return .result(dialog: "\(result.reply)")
    }
}

// MARK: Power and inputs

/// Turn on (on the last input used) or put in standby; a `SetValueIntent` so it can back
/// the Power control's toggle.
struct SetPowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Speaker On or Off"
    static let description = IntentDescription(
        "Turns your speaker on, on the input it last used, or puts it in standby.", categoryName: "Power")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "On", displayName: Bool.IntentDisplayName(true: "Turn on", false: "Turn off"))
    var value: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$value) the speaker")
    }

    init() {}

    init(on: Bool) {
        value = on
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.setPower(value)
        return .result(dialog: "\(result.reply)")
    }
}

struct SwitchInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Speaker Input"
    static let description = IntentDescription(
        "Switches your speaker to an input, turning it on if it is in standby.", categoryName: "Power")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Input", requestValueDialog: "Which input?", optionsProvider: SpeakerInputOptions())
    var input: SpeakerInput

    static var parameterSummary: some ParameterSummary {
        Summary("Switch the speaker to \(\.$input)")
    }

    init() {}

    init(input: SpeakerInput) {
        self.input = input
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.select(input)
        return .result(dialog: "\(result.reply)")
    }
}

// MARK: Playback

/// Play, pause, or either. The speaker only has a toggle, so "Pause" sends it only while
/// playing and "Play" only while paused: saying "Pause" never starts the music.
struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause Speaker"
    static let description = IntentDescription(
        "Plays or pauses your speaker, when what it's playing allows it. Pause never starts playback, and Play never pauses it.",
        categoryName: "Playback")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Action", default: .playPause)
    var action: PlaybackAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the speaker")
    }

    init() {}

    init(action: PlaybackAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.playPause(action.request)
        return .result(dialog: "\(result.reply)")
    }
}

/// What Play or Pause does. The raw values are saved in people's shortcuts, so they never
/// change; add cases at the end.
enum PlaybackAction: String, AppEnum {
    case playPause = "playPause"
    case play = "play"
    case pause = "pause"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Action")

    // The titles are also what Siri listens for ("Pause Speakeasy").
    static let caseDisplayRepresentations: [PlaybackAction: DisplayRepresentation] = [
        .playPause: DisplayRepresentation(title: "Play or Pause", image: .init(systemName: "playpause.fill")),
        .play: DisplayRepresentation(title: "Play", image: .init(systemName: "play.fill"), synonyms: ["Resume"]),
        .pause: DisplayRepresentation(title: "Pause", image: .init(systemName: "pause.fill")),
    ]

    var request: PlaybackRequest {
        switch self {
        case .playPause: .toggle
        case .play: .play
        case .pause: .pause
        }
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip to Next Track"
    static let description = IntentDescription(
        "Skips to the next track on your speaker, when what it's playing allows it.", categoryName: "Playback")
    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("Skip to the next track on the speaker")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.next()
        return .result(dialog: "\(result.reply)")
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to Previous Track"
    static let description = IntentDescription(
        "Goes back to the previous track on your speaker, when what it's playing allows it.", categoryName: "Playback")
    static var supportedModes: IntentModes { .background }

    static var parameterSummary: some ParameterSummary {
        Summary("Go to the previous track on the speaker")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await SpeakerActions.previous()
        return .result(dialog: "\(result.reply)")
    }
}
