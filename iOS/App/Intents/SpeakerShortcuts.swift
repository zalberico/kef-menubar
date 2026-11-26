import AppIntents

/// The phrases Siri knows without any setup, and the tiles in the Shortcuts app and
/// Spotlight. Phrases are a contract once shipped: add new ones rather than rewording.
/// At most 10 App Shortcuts are allowed; this uses 9.
///
/// App target only, like the intents it lists: a widget extension can't run App
/// Shortcuts ("couldn't find the AppShortcutsProvider"), and the system runs an intent in
/// the extension whenever the extension has it too.
struct SpeakerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: [
                "Turn up \(.applicationName)",
                "Turn \(.applicationName) up",
                "\(.applicationName) volume up",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.plus.fill")
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: [
                "Turn down \(.applicationName)",
                "Turn \(.applicationName) down",
                "\(.applicationName) volume down",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.minus.fill")
        AppShortcut(
            intent: SetVolumeIntent(),
            phrases: [
                "Set the volume in \(.applicationName)",
                "Set \(.applicationName) volume",
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2.fill")
        AppShortcut(
            intent: SetMuteIntent(muted: true),
            phrases: [
                "Mute \(.applicationName)",
                "Mute the speaker in \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash.fill")
        AppShortcut(
            intent: SetMuteIntent(muted: false),
            phrases: [
                "Unmute \(.applicationName)",
                "Unmute the speaker in \(.applicationName)",
            ],
            shortTitle: "Unmute",
            systemImageName: "speaker.wave.2.fill")
        AppShortcut(
            intent: SwitchInputIntent(),
            phrases: [
                "Switch \(.applicationName) to \(\.$input)",
                "Switch the input in \(.applicationName)",
                "Change the input in \(.applicationName)",
            ],
            shortTitle: "Switch Input",
            systemImageName: "rectangle.on.rectangle")
        AppShortcut(
            intent: SetPowerIntent(on: true),
            phrases: [
                "Turn on \(.applicationName)",
                "Turn \(.applicationName) on",
                "Wake up \(.applicationName)",
            ],
            shortTitle: "Turn On",
            systemImageName: "power")
        AppShortcut(
            intent: SetPowerIntent(on: false),
            phrases: [
                "Turn off \(.applicationName)",
                "Turn \(.applicationName) off",
                "Put \(.applicationName) in standby",
            ],
            shortTitle: "Standby",
            systemImageName: "powersleep")
        AppShortcut(
            intent: PlayPauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Play \(.applicationName)",
                "Play or pause \(.applicationName)",
            ],
            shortTitle: "Play or Pause",
            systemImageName: "playpause.fill")
    }
}
