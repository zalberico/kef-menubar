import KEFAppCore
import KEFKit
import SwiftUI

/// The current input's EQ profile, in the Mac popover's order and words: treble, bass,
/// desk and wall mode, balance, phase correction, then the subwoofers and the speakers'
/// high-pass. Every change writes the whole profile through `SpeakerModel.updateEQ`, which
/// coalesces a drag into one write in flight at a time, like the Mac.
struct SoundPanel: View {
    @Environment(SpeakerModel.self) private var model
    /// The profile hasn't come in a few seconds after the panel started waiting for it, and
    /// no input switch is reading one: the speaker didn't answer, and nothing retries until
    /// the next full read, so stop implying a read is under way.
    @State private var gaveUp = false

    var body: some View {
        let missingEQ = model.isOnline && model.eq == nil
        Group {
            if !model.isOnline {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "slider.horizontal.3")
                } description: {
                    Text("Sound settings show once Speakeasy reaches \(model.displayName).")
                }
            } else if let eq = model.eq {
                SoundForm(eq: eq)
            } else if gaveUp, !model.inputSettling {
                ContentUnavailableView {
                    Label("Sound Settings Unavailable", systemImage: "slider.horizontal.3")
                } description: {
                    Text("\(model.displayName) didn't send its sound settings.")
                } actions: {
                    Button("Try Again") {
                        gaveUp = false
                        model.retry()
                    }
                }
            } else {
                ProgressView("Reading sound settings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        if !Task.isCancelled { gaveUp = true }
                    }
            }
        }
        // A profile that arrives (or a lost connection) resets the wait for the next time.
        .onChange(of: missingEQ) { _, missing in
            if !missing { gaveUp = false }
        }
        .navigationTitle("Sound")
    }
}

/// Grouped cards in a ``PanelScrollView`` rather than a `Form`, so the scroll position
/// survives the move between the sheet and the column.
private struct SoundForm: View {
    let eq: EqProfile

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        // The Mac's rule: nothing can change while the speaker is off or a new input's
        // own profile hasn't been read back yet.
        let locked = !model.isOn || model.inputSettling
        let hasSubwoofer = eq.hasSubwoofer
        PanelScrollView(position: $ui.soundScroll, offset: $ui.soundOffset) {
            if !model.isOn {
                CardSection {
                    StandbyNotice(lastSource: model.lastSource)
                }
            }

            CardSection {
                if let name = eq.string(.profileName), !name.isEmpty {
                    LabeledRow("Profile") {
                        Text(name).foregroundStyle(.secondary)
                    }
                }
                EQSliderRow(title: "Treble", key: .trebleAmount, value: eq.double(.trebleAmount) ?? 0, unit: .decibels)
                EQChoiceRow(title: "Bass extension", key: .bassExtension,
                            value: eq.string(.bassExtension) ?? "standard", options: EQChoice.bassExtension)
                EQToggleSliderRow(title: "Desk mode", key: .deskMode, isOn: eq.bool(.deskMode) ?? false,
                                  settingKey: .deskModeSetting, setting: eq.double(.deskModeSetting) ?? 0,
                                  settingTitle: "Level", unit: .decibels)
                EQToggleSliderRow(title: "Wall mode", key: .wallMode, isOn: eq.bool(.wallMode) ?? false,
                                  settingKey: .wallModeSetting, setting: eq.double(.wallModeSetting) ?? 0,
                                  settingTitle: "Level", unit: .decibels)
                EQSliderRow(title: "Balance", key: .balance, value: eq.double(.balance) ?? 0, unit: .balance)
                EQToggleRow(title: "Phase correction", key: .phaseCorrection, isOn: eq.bool(.phaseCorrection) ?? false)
            }
            .disabled(locked)

            CardSection(header: "Subwoofers", footer: model.isOn
                        ? "Applies to the \(model.source?.displayName ?? "current") input's profile. The speaker keeps one per input."
                        : nil) {
                SubwooferCountRow(count: eq.subwooferCount)
                if hasSubwoofer {
                    EQSliderRow(title: "Sub level", key: .subwooferGain, value: eq.double(.subwooferGain) ?? 0, unit: .decibels)
                    if model.offersSubwooferPresets {
                        SubwooferPresetRows(
                            stored: eq.string(.subwooferPreset) ?? "",
                            defaults: eq.subwooferPreset.flatMap { preset in
                                eq.presetValues(preset).map { (preset, $0) }
                            },
                            isAtDefaults: eq.isAtPresetDefaults)
                    }
                    EQSliderRow(title: "Sub crossover", key: .subOutLPFreq, value: eq.double(.subOutLPFreq) ?? 80, unit: .hertz)
                }
                // Always reachable, like the Mac: with no sub it should normally be off
                // (full-range speakers), which setting the count to None does.
                EQToggleSliderRow(title: "Speaker high-pass", key: .highPassMode, isOn: eq.bool(.highPassMode) ?? false,
                                  settingKey: .highPassModeFreq, setting: eq.double(.highPassModeFreq) ?? 0,
                                  settingTitle: "Frequency", unit: .hertz)
                if hasSubwoofer {
                    EQChoiceRow(title: "Sub polarity", key: .subwooferPolarity,
                                value: eq.string(.subwooferPolarity) ?? "normal", options: EQChoice.polarity)
                    EQToggleRow(title: "Subwoofer output", key: .subwooferOut, isOn: eq.bool(.subwooferOut) ?? false)
                }
            }
            .disabled(locked)
        }
        .animation(.snappy(duration: 0.25), value: hasSubwoofer)
        .animation(.snappy(duration: 0.25), value: eq.bool(.deskMode))
        .animation(.snappy(duration: 0.25), value: eq.bool(.wallMode))
        .animation(.snappy(duration: 0.25), value: eq.bool(.highPassMode))
    }
}

/// Why everything below is dimmed, with the way out.
private struct StandbyNotice: View {
    let lastSource: Source

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Turn the speaker on to change its sound. The speaker keeps one profile per input.")
            } icon: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            Button {
                model.togglePower()
            } label: {
                Text("Turn On (\(lastSource.displayName))")
                    .fontWeight(.semibold)
            }
            .prominentGlassStyle()
        }
    }
}

// MARK: - Values

/// How a setting's value is shown and spoken.
enum EQUnit {
    case decibels, hertz, balance

    func text(_ value: Double) -> String {
        switch self {
        case .decibels: Fmt.signedDB(value)
        case .hertz: Fmt.hertz(value)
        case .balance: Fmt.balance(value)
        }
    }

    /// What VoiceOver says: "minus 1.5 decibels", "67.5 hertz", "Left 3".
    func spoken(_ value: Double) -> String {
        switch self {
        case .decibels:
            let number = Self.number(abs(value))
            return value > 0 ? "plus \(number) decibels" : (value < 0 ? "minus \(number) decibels" : "0 decibels")
        case .hertz:
            return "\(Self.number(value)) hertz"
        case .balance:
            let steps = Int(value)
            return steps == 0 ? "Center" : (steps < 0 ? "Left \(-steps)" : "Right \(steps)")
        }
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}

/// One segment of a choice row.
struct EQChoice<Tag: Hashable & Sendable>: Identifiable, Sendable {
    let label: String
    let tag: Tag
    var id: Tag { tag }
}

extension EQChoice<String> {
    static let bassExtension = [EQChoice(label: "Less", tag: "less"), EQChoice(label: "Standard", tag: "standard"),
                                EQChoice(label: "Extra", tag: "extra")]
    static let polarity = [EQChoice(label: "Normal", tag: "normal"), EQChoice(label: "Inverted", tag: "inverted")]
}

// MARK: - Rows

/// Title, value and a slider snapped to the speaker's step. Each snapped change is handed
/// to the model, whose single writer sends the latest one at most every 120 ms.
private struct EQSliderRow: View {
    let title: String
    let key: EqKey
    let value: Double
    let unit: EQUnit
    /// The spoken name when the visible title leans on the row above ("Level").
    var accessibilityTitle: String?

    @Environment(SpeakerModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let range = model.range(key)
        let caption = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: 6) {
            caption {
                Text(title)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                Text(unit.text(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
            }
            .accessibilityHidden(true)  // the slider says both

            // Signed settings fill from 0 (the speaker's neutral), not from the minimum.
            Slider(value: Binding(get: { value }, set: { raw in write(range.snap(raw)) }), in: range.closed,
                   neutralValue: range.closed.contains(0) ? 0 : nil) {
                Text(accessibilityTitle ?? title)
            }
            .accessibilityValue(unit.spoken(value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: write(range.snap(value + range.step))
                case .decrement: write(range.snap(value - range.step))
                @unknown default: break
                }
            }
        }
    }

    private func write(_ snapped: Double) {
        guard snapped != value else { return }
        model.updateEQ { profile in
            // Balance is an integer number of steps on the wire, as on the Mac.
            if key == .balance { profile[.balance] = .int(Int64(snapped)) } else { profile.set(key, snapped) }
        }
    }
}

private struct EQToggleRow: View {
    let title: String
    let key: EqKey
    let isOn: Bool

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        // No haptic on the tap, as for the remote's switches; a refused write buzzes with
        // its banner (CommandHaptics).
        Toggle(title, isOn: Binding(get: { isOn }, set: { on in
            model.updateEQ { $0.set(key, on) }
        }))
    }
}

/// A switch, and the slider that tunes it while it's on (desk / wall mode dB, high-pass Hz).
private struct EQToggleSliderRow: View {
    let title: String
    let key: EqKey
    let isOn: Bool
    let settingKey: EqKey
    let setting: Double
    let settingTitle: String
    let unit: EQUnit

    var body: some View {
        // One row: the slider reads as part of its switch.
        VStack(alignment: .leading, spacing: 12) {
            EQToggleRow(title: title, key: key, isOn: isOn)
            if isOn {
                EQSliderRow(title: settingTitle, key: settingKey, value: setting, unit: unit,
                            accessibilityTitle: "\(title) \(settingTitle.lowercased())")
                    .transition(.opacity)
            }
        }
    }
}
private struct EQChoiceRow: View {
    let title: String
    let key: EqKey
    let value: String
    let options: [EQChoice<String>]

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        ChoiceRow(title: title, selection: value, options: options) { tag in
            model.updateEQ { $0.set(key, tag) }
        }
    }
}

/// How many wired subwoofers this input's profile drives. Setting None turns the speakers'
/// high-pass off and the first sub turns it back on (KEFKit's rule).
private struct SubwooferCountRow: View {
    let count: Int

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let maxCount = max(1, Int(model.range(.subwooferCount).max.rounded()))
        let options = [EQChoice(label: "None", tag: 0)] + (1...maxCount).map { EQChoice(label: "\($0)", tag: $0) }
        ChoiceRow(title: "Subwoofers", selection: count, options: options, showsTitle: false) { n in
            model.updateEQ { $0.setSubwooferCount(n) }
        }
    }
}

/// The sub model (KEF Connect's presets) and a way back to its default gain, crossover and
/// high-pass after manual tweaks.
private struct SubwooferPresetRows: View {
    /// The profile's preset as stored ("kc62", or "custom" and the like).
    let stored: String
    /// The chosen preset and its defaults for this setup, when both are known.
    let defaults: (SubwooferPreset, SubwooferPreset.Values)?
    let isAtDefaults: Bool

    @Environment(SpeakerModel.self) private var model
    @State private var changes = 0
    @State private var noDefaults = false

    var body: some View {
        LabeledRow("Sub model") {
            MenuPicker(title: "Sub model", valueLabel: SubwooferPreset(rawValue: stored)?.title ?? "Other") {
                Picker("Sub model", selection: Binding(get: { stored }, set: { raw in
                    guard raw != stored, let preset = SubwooferPreset(rawValue: raw) else { return }
                    changes += 1
                    apply(preset)
                })) {
                    ForEach(SubwooferPreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                    if SubwooferPreset(rawValue: stored) == nil {
                        Text("Other").tag(stored)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: changes)

        if noDefaults {
            Label("No defaults for this sub with this speaker", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                // Restarts with each pick, so a second miss gets its full 4 s.
                .task(id: changes) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy(duration: 0.25)) { noDefaults = false }
                }
        }

        if let defaults, !isAtDefaults {
            let (preset, values) = defaults
            VStack(alignment: .leading, spacing: 4) {
                Button("Restore \(preset.title) Defaults") {
                    changes += 1
                    apply(preset)
                }
                .accessibilityHint("Sets the sub gain, crossover and speaker high-pass back to the \(preset.title) defaults")
                Text("Defaults: \(Fmt.signedDB(values.gain)), \(Fmt.hertz(values.crossover)), high-pass \(Fmt.hertz(values.highPass))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Defaults: \(EQUnit.decibels.spoken(values.gain)), \(EQUnit.hertz.spoken(values.crossover)), high-pass \(EQUnit.hertz.spoken(values.highPass))")
            }
        }
    }

    /// `applySubwooferPreset` changes nothing when KEF's tables have no entry for this sub
    /// with this speaker's setup (a T2 on a KW1 kit); say so instead of silently snapping back.
    private func apply(_ preset: SubwooferPreset) {
        if model.applySubwooferPreset(preset) {
            withAnimation(.snappy(duration: 0.25)) { noDefaults = false }
        } else if !model.inputSettling {
            // Animated: the rows below (Restore among them) slide rather than jump.
            withAnimation(.snappy(duration: 0.25)) { noDefaults = true }
            AccessibilityNotification.Announcement("No defaults for this sub with this speaker").post()
        }
    }
}
