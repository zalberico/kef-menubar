#if DEBUG
import AppIntents

/// Debug only: reads the speaker once from wherever the system runs it (the widget
/// extension for the control, the app or extension from Shortcuts) and logs the outcome,
/// to check that local-network access works outside the app. Never writes to the speaker.
struct ProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Speaker Probe"
    static let description = IntentDescription("Debug: reads the speaker once and logs whether it could be reached.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let line = await SpeakerProbe.run()
        return .result(value: line, dialog: "\(line)")
    }
}
#endif
