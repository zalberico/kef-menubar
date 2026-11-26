import AppIntents
import KEFAppCore
import KEFKit
import SwiftUI
import WidgetKit

/// What the Power and Mute controls show: the speaker's last known state. Both read it
/// through one shared read (``SpeakerAccess/currentSnapshot()``), so opening Control Center
/// reaches the speaker once, and offline they show the last stored state.
struct SpeakerControlState: Sendable {
    var name: String
    var isOn: Bool
    var muted: Bool

    init(name: String, isOn: Bool, muted: Bool) {
        self.name = name
        self.isOn = isOn
        self.muted = muted
    }

    init(_ snapshot: SpeakerSnapshot?) {
        self.init(name: snapshot?.name ?? "", isOn: snapshot?.isOn ?? false, muted: snapshot?.muted ?? false)
    }

    static let preview = SpeakerControlState(name: "", isOn: true, muted: false)
}

struct SpeakerControlProvider: ControlValueProvider {
    var previewValue: SpeakerControlState { .preview }

    func currentValue() async throws -> SpeakerControlState {
        SpeakerControlState(await SpeakerAccess.currentSnapshot().snapshot)
    }
}

/// The speaker's name as a control's title, "Speaker" until the app has found it.
private struct SpeakerTitle: View {
    let name: String

    var body: some View {
        if name.isEmpty {
            Text("Speaker")
        } else {
            Text(verbatim: name)
        }
    }
}

/// Power: on, on the last input used, or standby.
struct PowerControl: ControlWidget {
    static let kind = "SpeakerPower"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: SpeakerControlProvider()) { state in
            ControlWidgetToggle(isOn: state.isOn, action: WidgetSetPowerIntent()) {
                Label {
                    SpeakerTitle(name: state.name)
                } icon: {
                    Image(systemName: "power")
                }
            } valueLabel: { isOn in
                Label(isOn ? "On" : "Standby", systemImage: "power")
            }
            .tint(Color("AccentColor"))
        }
        .displayName("Speaker Power")
        .description("Turns your speaker on, on the input it last used, or puts it in standby.")
    }
}

/// Mute: on means muted.
struct MuteControl: ControlWidget {
    static let kind = "SpeakerMute"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: SpeakerControlProvider()) { state in
            ControlWidgetToggle(isOn: state.muted, action: WidgetSetMuteIntent()) {
                Label("Mute", systemImage: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            } valueLabel: { muted in
                Label(muted ? "Muted" : "Sound On", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .tint(Color("AccentColor"))
        }
        .displayName("Speaker Mute")
        .description("Mutes or unmutes your speaker.")
    }
}

// MARK: Input

/// The input an Input control switches to, chosen when adding the control.
struct InputControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Speaker Input"
    static let description = IntentDescription("Choose the input this control switches your speaker to.")

    @Parameter(title: "Input", default: .tv, optionsProvider: SpeakerInputOptions())
    var input: SpeakerInput
}

struct InputControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: InputControlConfiguration) -> SpeakerInput {
        configuration.input
    }

    func currentValue(configuration: InputControlConfiguration) async throws -> SpeakerInput {
        configuration.input
    }
}

/// A button that switches the speaker to one input (and wakes it).
struct InputControl: ControlWidget {
    static let kind = "SpeakerInput"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: Self.kind, provider: InputControlProvider()) { input in
            ControlWidgetButton(action: WidgetSwitchInputIntent(input: input)) {
                Label {
                    Text(SpeakerInput.caseDisplayRepresentations[input]?.title ?? "Input")
                } icon: {
                    Image(systemName: input.systemImage)
                }
            }
            .tint(Color("AccentColor"))
        }
        .displayName("Speaker Input")
        .description("Switches your speaker to the input you choose, turning it on if needed.")
        .promptsForUserConfiguration()
    }
}
