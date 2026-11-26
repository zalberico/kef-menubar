import KEFAppCore
import KEFKit
import SwiftUI

/// The speaker's own settings, in the Mac app's order and words (name, power, startup
/// volume, volume limit, lights and sound, the remote, firmware), then Speakeasy's own
/// preference and the about notes. Everything typed or half-dragged lives in ``UIState``,
/// so moving between the sheet and the column (folding the Duo) loses nothing.
struct SettingsPanel: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        PanelScrollView(position: $ui.settingsScroll, offset: $ui.settingsOffset) {
            if let error = model.lastError {
                CardSection {
                    Label {
                        Text(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                }
                .transition(.opacity)
            }

            SpeakerSettingsCards()
            FirmwareCard()

            // About every card above, so set apart from the Firmware card's own footer.
            Text("These settings are stored on the speaker. This app never resets, reboots or reconfigures the speaker's network.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 28)

            AppPreferencesCard()
            AboutCard()
        }
        .navigationTitle("Settings")
        .alert(model.firmwareUpdateAlertTitle, isPresented: Binding(
            // Never asks about an update that has gone (installed meanwhile, another speaker).
            get: { ui.confirmingFirmwareUpdate && model.firmwareUpdateAvailable },
            set: { ui.confirmingFirmwareUpdate = $0 })
        ) {
            Button("Update") {
                ui.confirmingFirmwareUpdate = false
                // Re-checks that the speaker still offers the update before it starts.
                model.installFirmwareUpdate()
            }
            Button("Cancel", role: .cancel) {
                ui.confirmingFirmwareUpdate = false
            }
        } message: {
            Text(SpeakerModel.firmwareUpdateAlertMessage)
        }
        .onAppear {
            model.loadSpeakerSettings()
            reconcileRename(feedback: false)
        }
        .onChange(of: model.isOnline) { _, online in
            if online { model.loadSpeakerSettings() }
        }
        .onChange(of: model.firmwareUpdateAvailable) { _, available in
            // An alert the update's going took away (offline, a check, another speaker)
            // never comes back by itself.
            if !available { ui.confirmingFirmwareUpdate = false }
        }
        .onChange(of: model.name) { reconcileRename() }
        .onChange(of: model.preferences.lastSpeakerName) { reconcileRename() }
        .animation(.snappy(duration: 0.25), value: model.lastError)
        .animation(.snappy(duration: 0.25), value: model.speakerSettings)
        .animation(.snappy(duration: 0.25), value: model.firmwareProgress)
    }

    private func reconcileRename(feedback: Bool = true) {
        ui.reconcileRename(modelName: model.name, savedName: model.preferences.lastSpeakerName,
                           feedback: feedback)
    }
}

/// The speaker's settings once read, or why they aren't shown (the Mac's three states).
private struct SpeakerSettingsCards: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        if model.isOnline, let settings = model.speakerSettings {
            NameCard()
            PowerCard(settings: settings, inputs: model.inputs)
            StartupVolumeCard(settings: settings, inputs: model.inputs, ceiling: model.volumeCeiling,
                              limited: model.volumeLimited)
            VolumeLimitCard(limited: model.volumeLimited, maximum: model.maximumVolume)
            LightsAndRemoteCards(settings: settings)
        } else if model.isOnline && model.speakerSettingsFailed {
            CardSection {
                AdaptiveRow {
                    Text("Couldn't read the speaker's settings.")
                        .foregroundStyle(.secondary)
                } trailing: {
                    Button("Retry") {
                        model.loadSpeakerSettings()
                    }
                }
            }
        } else {
            CardSection {
                if model.isOnline {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the speaker's settings…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Connect to the speaker to change its settings.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Name

private struct NameCard: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @FocusState private var editing: Bool

    /// The speaker's limit (KEFKit refuses longer names too).
    private static let maxLength = 64

    var body: some View {
        let text = ui.renameDraft ?? model.name
        let pending = ui.pendingRename != nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let edited = trimmed != model.name
        let tooLong = trimmed.count > Self.maxLength
        CardSection(header: "Name", footer: "Also the name shown for AirPlay, Spotify Connect and Bluetooth.") {
            VStack(alignment: .leading, spacing: 6) {
                AdaptiveRow {
                    HStack(spacing: 8) {
                        TextField("Speaker name", text: Binding(get: { text }, set: { ui.renameDraft = $0 }))
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($editing)
                            .onSubmit { rename(text) }
                            .disabled(pending)
                        if !pending && !edited {
                            // Says the name can be edited; the field itself is what VoiceOver reads.
                            Button {
                                editing = true
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)
                        }
                    }
                } trailing: {
                    // Only once there is something to send, so it never reads as a hint.
                    if pending {
                        ProgressView()
                            .accessibilityLabel("Renaming")
                    } else if edited {
                        Button("Rename") {
                            rename(text)
                        }
                        .disabled(!model.canRename(text))
                    }
                }
                if tooLong {
                    Text("A name can be \(Self.maxLength) characters at most.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        // When the speaker answers, not when the name is sent (a refusal's error haptic
        // comes with its banner, from CommandHaptics).
        .sensoryFeedback(.success, trigger: ui.renamesConfirmed)
    }

    private func rename(_ text: String) {
        guard model.canRename(text) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ui.pendingRename = trimmed
        ui.renameDraft = trimmed
        model.rename(trimmed)
    }
}

// MARK: - Power

private struct PowerCard: View {
    let settings: SpeakerSettings
    let inputs: [Source]

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let autoTV = inputs.contains(.tv) ? settings.autoSwitchToTV : nil
        if settings.standbyMode != nil || settings.wakeSourceRaw != nil || autoTV != nil {
            CardSection(header: "Power") {
                if let mode = settings.standbyMode {
                    // Like KEF Connect: ECO only with the default wake source.
                    MenuChoiceRow(title: "Auto standby", selection: mode,
                                  options: StandbyMode.options(current: mode, wakeRaw: settings.wakeSourceRaw)
                                      .map { EQChoice(label: $0.title, tag: $0) }) { choice in
                        model.setStandbyMode(choice)
                    }
                }
                if let wake = settings.wakeSource {
                    VStack(alignment: .leading, spacing: 6) {
                        MenuChoiceRow(title: "Wake from standby on", selection: wake,
                                      options: WakeSource.options(for: inputs, current: wake)
                                          .map { EQChoice(label: $0.title, tag: $0) }) { choice in
                            model.setWakeSource(choice)
                        }
                        Text(WakeSource.caption(standbyMode: settings.standbyMode))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let raw = settings.wakeSourceRaw {
                    LabeledRow("Wake from standby on") {
                        Text(raw).foregroundStyle(.secondary)
                    }
                }
                if let autoTV {
                    SettingToggle(title: "Switch to TV when the TV turns on", isOn: autoTV) { on in
                        model.setAutoSwitchToTV(on)
                    }
                }
            }
        }
    }
}

// MARK: - Startup volume

private struct StartupVolumeCard: View {
    let settings: SpeakerSettings
    let inputs: [Source]
    let ceiling: Int
    let limited: Bool

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        if let enabled = settings.startupVolumeEnabled {
            CardSection(
                header: "Startup volume",
                footer: enabled
                    ? "The speaker returns to this volume each time it wakes from standby\(limited ? ", up to the volume limit" : "")."
                    : "Off: the speaker wakes at the volume it had when it went to standby.") {
                SettingToggle(title: "Reset volume after standby", isOn: enabled) { on in
                    model.setStartupVolumeEnabled(on)
                }
                if enabled {
                    if let perInput = settings.startupVolumePerInput {
                        SettingToggle(title: "Separate volume for each input", isOn: perInput) { on in
                            model.setStartupVolumePerInput(on)
                        }
                    }
                    if settings.startupVolumePerInput == true {
                        ForEach(inputs.filter { settings.startupVolumes[$0] != nil }) { source in
                            VolumeSettingRow(title: source.displayName,
                                             spokenTitle: "\(source.displayName) startup volume",
                                             draftKey: source.rawValue,
                                             value: settings.startupVolumes[source] ?? 0,
                                             ceiling: ceiling, limited: limited) { level in
                                model.setStartupVolume(level, for: source)
                            }
                        }
                    } else if let level = settings.startupVolume {
                        VolumeSettingRow(title: "Volume", spokenTitle: "Startup volume", draftKey: "all",
                                         value: level, ceiling: ceiling, limited: limited) { level in
                            model.setStartupVolume(level)
                        }
                    }
                }
            }
        }
    }
}

/// A 0–100 volume setting that writes when the slider is released, not on every step. Like
/// the main volume slider, the track is always 0–100 with a tick at the limit and the part
/// above it disabled, so a level sits where it does there; a level stored above the limit
/// shows past the tick and is marked.
private struct VolumeSettingRow: View {
    let title: String
    let spokenTitle: String
    /// Where the drag is kept in ``UIState``.
    let draftKey: String
    let value: Int
    /// The volume limit (100 without one).
    let ceiling: Int
    let limited: Bool
    let commit: (Int) -> Void

    @Environment(UIState.self) private var ui

    var body: some View {
        let draft = ui.startupVolumeDrafts[draftKey]
        let shown = draft ?? Double(min(max(value, 0), 100))
        let aboveLimit = value > ceiling && draft == nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    if aboveLimit {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                    }
                    Text("\(draft.map { Int($0) } ?? value)")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: shown))
                }
                .foregroundStyle(aboveLimit ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .accessibilityHidden(true)  // the slider says both

            Slider(value: Binding(get: { shown }, set: { ui.startupVolumeDrafts[draftKey] = $0.rounded() }),
                   in: 0...100,
                   enabledBounds: limited ? 0...Double(max(ceiling, 1)) : nil,
                   label: { Text(spokenTitle) },
                   onEditingChanged: { editing in
                       guard !editing, let draft = ui.startupVolumeDrafts[draftKey] else { return }
                       ui.startupVolumeDrafts[draftKey] = nil
                       if Int(draft) != value { commit(Int(draft)) }
                   })
                .background {
                    if limited { LimitTick(fraction: Double(ceiling) / 100) }
                }
                // The draft is there only while dragging: the main volume slider's ticks.
                .modifier(LevelTicks(level: draft.map { Int($0) }, ceiling: limited ? max(ceiling, 1) : 100))
                .accessibilityValue(aboveLimit ? "\(value), above the volume limit of \(ceiling)" : "\(Int(shown))")
                .accessibilityAdjustableAction { direction in
                    let current = min(value, ceiling)
                    switch direction {
                    case .increment: if current < ceiling { commit(current + 1) }
                    case .decrement: if current > 0 { commit(current - 1) }
                    @unknown default: break
                    }
                }

            if aboveLimit {
                Text("Stored above the volume limit (\(ceiling))")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)  // in the slider's value
            }
        }
    }
}

// MARK: - Volume limit

private struct VolumeLimitCard: View {
    let limited: Bool
    let maximum: Int

    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        let shown = ui.maximumVolumeDraft ?? Double(maximum)
        CardSection(header: "Volume limit") {
            SettingToggle(title: "Limit maximum volume", isOn: limited) { on in
                model.setVolumeLimited(on)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Maximum volume")
                    Spacer(minLength: 8)
                    Text("\(Int(shown))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: shown))
                }
                .accessibilityHidden(true)  // the slider says both

                Slider(value: Binding(get: { shown }, set: { ui.maximumVolumeDraft = $0.rounded() }),
                       in: 1...100,
                       label: { Text("Maximum volume") },
                       onEditingChanged: { editing in
                           guard !editing, let draft = ui.maximumVolumeDraft else { return }
                           ui.maximumVolumeDraft = nil
                           if Int(draft) != maximum { model.setMaximumVolume(Int(draft)) }
                       })
                    .modifier(LevelTicks(level: ui.maximumVolumeDraft.map { Int($0) }, ceiling: 100))
                    .accessibilityValue("\(Int(shown))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: if maximum < 100 { model.setMaximumVolume(maximum + 1) }
                        case .decrement: if maximum > 1 { model.setMaximumVolume(maximum - 1) }
                        @unknown default: break
                        }
                    }
            }
            .disabled(!limited)
            .opacity(limited ? 1 : 0.5)
        }
    }
}

// MARK: - Lights and sound, remote

private struct LightsAndRemoteCards: View {
    let settings: SpeakerSettings

    @Environment(SpeakerModel.self) private var model

    var body: some View {
        if settings.standbyLight != nil || settings.startupTone != nil {
            CardSection(header: "Lights and sound") {
                if let light = settings.standbyLight {
                    SettingToggle(title: "Standby light", isOn: light) { on in
                        model.setStandbyLight(on)
                    }
                }
                if let tone = settings.startupTone {
                    SettingToggle(title: "Startup sound", isOn: tone) { on in
                        model.setStartupTone(on)
                    }
                }
            }
        }
        if settings.remoteEnabled != nil || settings.remoteVolumeStep != nil {
            CardSection(header: "Remote",
                        footer: settings.remoteVolumeStep != nil ? "For KEF's remote and the buttons on the speaker." : nil) {
                if let remote = settings.remoteEnabled {
                    SettingToggle(title: "Respond to the remote", isOn: remote) { on in
                        model.setRemoteEnabled(on)
                    }
                }
                if let step = settings.remoteVolumeStep {
                    StepperRow(title: "Volume step", spokenTitle: "Remote volume step", value: step) { newStep in
                        model.setRemoteVolumeStep(newStep)
                    }
                }
            }
        }
    }
}

// MARK: - Firmware

private struct FirmwareCard: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let checking = model.firmwareActivity == .checking
        CardSection(header: "Firmware",
                    footer: "This app only starts an update after you confirm. The speaker also checks for updates by itself every few hours and can install them while idle.") {
            LabeledRow("Installed") {
                Text(model.firmware.map { shortFirmwareVersion($0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            LabeledRow("Status") {
                Text(model.firmwareStatusText)
                    .foregroundStyle(.secondary)
                    // Under the title at accessibility sizes, so it lines up on the left.
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
            if let progress = model.firmwareProgress {
                let percent = min(max(progress, 0), 100)
                ProgressView(value: Double(percent), total: 100) {
                    Text("Firmware progress")
                }
                .labelsHidden()
                .accessibilityValue("\(percent) percent")
            }
            if let notice = model.firmwareNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            AdaptiveRow {
                Button(checking ? "Checking…" : "Check Now") {
                    model.checkForFirmwareUpdate()
                }
                .disabled(!model.isOnline || model.firmwareActivity != .idle || model.firmwareInstalling)
            } trailing: {
                if model.firmwareUpdateAvailable {
                    Button {
                        ui.confirmingFirmwareUpdate = true
                    } label: {
                        Text("Update…")
                            .fontWeight(.semibold)
                    }
                    .prominentGlassStyle()
                    .accessibilityHint("Asks before the speaker installs the update")
                }
            }
        }
    }
}

// MARK: - Speakeasy

/// The app's own preference, apart from the speaker's: the step of the − and + buttons.
private struct AppPreferencesCard: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        CardSection(header: "Speakeasy", footer: "Used by the − and + buttons, widgets, Control Center and Siri.") {
            StepperRow(title: "Volume button step", spokenTitle: "Volume button step",
                       value: PreferenceKey.volumeStep(preferences.volumeStep)) { step in
                preferences.volumeStep = min(max(step, PreferenceKey.volumeStepRange.lowerBound),
                                             PreferenceKey.volumeStepRange.upperBound)
            }
        }
    }
}

private struct AboutCard: View {
    private static let readMe = URL(string: "https://github.com/zalberico/kef-menubar#readme")!

    var body: some View {
        CardSection(header: "About") {
            LabeledRow("Version") {
                Text(Self.version)
                    .foregroundStyle(.secondary)
            }
            Text("Speakeasy talks only to your speaker, on your local network. No accounts, no analytics. Album art may load from the address your speaker reports.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link(destination: Self.readMe) {
                Label("Read Me on GitHub", systemImage: "arrow.up.right.square")
            }
            .accessibilityHint("Opens the project's page in Safari")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - Rows

/// A switch. Like mute on the remote it has no haptic of its own on the tap; a write the
/// speaker refuses buzzes with its banner (CommandHaptics).
private struct SettingToggle: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { on in set(on) }))
    }
}

/// A choice from a list, as a menu showing the current value.
private struct MenuChoiceRow<Tag: Hashable & Sendable>: View {
    let title: String
    let selection: Tag
    let options: [EQChoice<Tag>]
    let choose: (Tag) -> Void

    @State private var changes = 0

    var body: some View {
        LabeledRow(title) {
            MenuPicker(title: title, valueLabel: options.first { $0.tag == selection }?.label ?? "") {
                Picker(title, selection: Binding(get: { selection }, set: { tag in
                    guard tag != selection else { return }
                    changes += 1
                    choose(tag)
                })) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.tag)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: changes)
    }
}

/// A 1–10 step. The value sits beside the title, or above the buttons at accessibility sizes.
private struct StepperRow: View {
    let title: String
    let spokenTitle: String
    let value: Int
    let set: (Int) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var changes = 0

    var body: some View {
        let binding = Binding(get: { value }, set: { (step: Int) in
            guard step != value else { return }
            changes += 1
            set(step)
        })
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .accessibilityHidden(true)
                    Stepper(value: binding, in: 1...10, label: {
                        Text("\(value)").monospacedDigit()
                    })
                }
            } else {
                Stepper(value: binding, in: 1...10, label: {
                    HStack {
                        Text(title)
                        Spacer(minLength: 8)
                        Text("\(value)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(value)))
                    }
                })
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenTitle)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < 10 { binding.wrappedValue = value + 1 }
            case .decrement: if value > 1 { binding.wrappedValue = value - 1 }
            @unknown default: break
            }
        }
        .sensoryFeedback(.selection, trigger: changes)
    }
}

/// Something and its trailing control on one line, or stacked at accessibility sizes.
private struct AdaptiveRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                leading
                trailing
            }
        } else {
            HStack(spacing: 12) {
                leading
                Spacer(minLength: 0)
                trailing
            }
        }
    }
}
