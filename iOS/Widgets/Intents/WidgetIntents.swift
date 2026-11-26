import AppIntents
import KEFAppCore

// The widget's buttons and the controls run these, in the widget extension, so a tap
// reaches the speaker without launching the app. They are hidden from Shortcuts and
// Spotlight (the app's own intents are the public ones), do the same as those, and return
// no dialog: nothing would show it.
//
// The type names are saved with placed controls: never rename them.

struct WidgetVolumeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Up"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        _ = try await SpeakerActions.step(.up)
        return .result()
    }
}

struct WidgetVolumeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Speaker Volume Down"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        _ = try await SpeakerActions.step(.down)
        return .result()
    }
}

/// The Mute control's toggle and the widget's mute button.
struct WidgetSetMuteIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Mute or Unmute Speaker"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Muted")
    var value: Bool

    init() {}

    init(muted: Bool) {
        value = muted
    }

    func perform() async throws -> some IntentResult {
        _ = try await SpeakerActions.setMuted(value)
        return .result()
    }
}

/// The Power control's toggle and the widget's Turn On button.
struct WidgetSetPowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Speaker On or Off"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "On")
    var value: Bool

    init() {}

    init(on: Bool) {
        value = on
    }

    func perform() async throws -> some IntentResult {
        _ = try await SpeakerActions.setPower(value)
        return .result()
    }
}

/// The Input control's button.
struct WidgetSwitchInputIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Speaker Input"
    static let isDiscoverable = false
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Input")
    var input: SpeakerInput

    init() {}

    init(input: SpeakerInput) {
        self.input = input
    }

    func perform() async throws -> some IntentResult {
        _ = try await SpeakerActions.select(input)
        return .result()
    }
}
