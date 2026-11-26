import KEFAppCore
import KEFKit
import SwiftUI

/// The speaker's own settings, as KEF Connect has them: name, power and standby, startup
/// volume, volume limit, lights and sound, the remote, and firmware.
struct SpeakerSettingsTab: View {
    @Environment(SpeakerModel.self) private var model
    @State private var newName = ""
    @State private var maximumVolume = 100
    @State private var confirmingUpdate = false
    /// A name sent to the speaker; keeps the field's text if the rename fails.
    @State private var pendingName: String?

    var body: some View {
        Form {
            if let error = model.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if model.isOnline, let settings = model.speakerSettings {
                nameSection
                powerSection(settings)
                startupVolumeSection(settings)
                volumeLimitSection
                lightsAndRemoteSection(settings)
            } else if model.isOnline && model.speakerSettingsFailed {
                Section {
                    HStack {
                        Text("Couldn't read the speaker's settings.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { model.loadSpeakerSettings() }
                    }
                }
            } else {
                Section {
                    Text(model.isOnline ? "Reading the speaker's settings…" : "Connect to the speaker to change its settings.")
                        .foregroundStyle(.secondary)
                }
            }
            firmwareSection
            Section {
                Text("These settings are stored on the speaker. Firmware updates only start after you confirm. This app never resets, reboots or reconfigures the speaker's network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 620)
        .alert(model.firmwareUpdateAlertTitle, isPresented: $confirmingUpdate) {
            Button("Update") { model.installFirmwareUpdate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SpeakerModel.firmwareUpdateAlertMessage)
        }
        .onAppear {
            newName = model.name
            maximumVolume = model.maximumVolume
            model.loadSpeakerSettings()
        }
        .onChange(of: model.isOnline) { _, online in if online { model.loadSpeakerSettings() } }
        .onChange(of: model.name) { _, name in
            // While a rename is pending, or after it failed, keep what was typed.
            if let pending = pendingName {
                if name == pending { pendingName = nil; newName = name }
                return
            }
            newName = name
        }
        .onChange(of: model.lastError) { _, error in
            if error != nil, pendingName != nil, model.name != pendingName { pendingName = nil }
        }
        .onChange(of: model.maximumVolume) { _, value in maximumVolume = value }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section("Name") {
            HStack {
                TextField("Name", text: $newName, prompt: Text("Speaker name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rename() }
                Button("Rename") { rename() }
                    .disabled(!canRename)
            }
            Text("Also the name shown for AirPlay, Spotify Connect and Bluetooth.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func powerSection(_ settings: SpeakerSettings) -> some View {
        let autoTV = model.inputs.contains(.tv) ? settings.autoSwitchToTV : nil
        if settings.standbyMode != nil || settings.wakeSourceRaw != nil || autoTV != nil {
            Section("Power") {
                if let mode = settings.standbyMode {
                    Picker("Auto standby", selection: Binding(get: { mode }, set: { model.setStandbyMode($0) })) {
                        // Like KEF Connect: ECO only with the default wake source.
                        ForEach(StandbyMode.options(current: mode, wakeRaw: settings.wakeSourceRaw)) {
                            Text($0.title).tag($0)
                        }
                    }
                }
                if let wake = settings.wakeSource {
                    Picker("Wake from standby on", selection: Binding(get: { wake }, set: { model.setWakeSource($0) })) {
                        ForEach(WakeSource.options(for: model.inputs, current: wake)) { Text($0.title).tag($0) }
                    }
                    Text(WakeSource.caption(standbyMode: settings.standbyMode))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let raw = settings.wakeSourceRaw {
                    LabeledContent("Wake from standby on") { Text(raw).foregroundStyle(.secondary) }
                }
                if let autoTV {
                    Toggle("Switch to TV when the TV turns on", isOn: Binding(get: { autoTV }, set: { model.setAutoSwitchToTV($0) }))
                }
            }
        }
    }

    @ViewBuilder
    private func startupVolumeSection(_ settings: SpeakerSettings) -> some View {
        if let enabled = settings.startupVolumeEnabled {
            Section("Startup volume") {
                Toggle("Reset volume after standby", isOn: Binding(get: { enabled }, set: { model.setStartupVolumeEnabled($0) }))
                if enabled {
                    if let perInput = settings.startupVolumePerInput {
                        Toggle("Separate volume for each input", isOn: Binding(get: { perInput }, set: { model.setStartupVolumePerInput($0) }))
                    }
                    if settings.startupVolumePerInput == true {
                        ForEach(model.inputs.filter { settings.startupVolumes[$0] != nil }) { source in
                            VolumeSettingRow(title: source.displayName, value: settings.startupVolumes[source] ?? 0,
                                             ceiling: model.volumeCeiling) {
                                model.setStartupVolume($0, for: source)
                            }
                        }
                    } else if let level = settings.startupVolume {
                        VolumeSettingRow(title: "Volume", value: level, ceiling: model.volumeCeiling) { model.setStartupVolume($0) }
                    }
                }
                Text(enabled
                     ? "The speaker returns to this volume each time it wakes from standby\(model.volumeLimited ? ", up to the volume limit" : "")."
                     : "Off: the speaker wakes at the volume it had when it went to standby.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var volumeLimitSection: some View {
        Section("Volume limit") {
            Toggle("Limit maximum volume", isOn: Binding(get: { model.volumeLimited }, set: { model.setVolumeLimited($0) }))
            HStack {
                Text("Maximum volume")
                Slider(value: Binding(get: { Double(maximumVolume) }, set: { maximumVolume = Int($0.rounded()) }),
                       in: 1...100, onEditingChanged: { editing in
                           if !editing, maximumVolume != model.maximumVolume { model.setMaximumVolume(maximumVolume) }
                       })
                Text("\(maximumVolume)").monospacedDigit().frame(width: 30, alignment: .trailing)
            }
            .disabled(!model.volumeLimited)
        }
    }

    @ViewBuilder
    private func lightsAndRemoteSection(_ settings: SpeakerSettings) -> some View {
        if settings.standbyLight != nil || settings.startupTone != nil {
        Section("Lights and sound") {
            if let light = settings.standbyLight {
                Toggle("Standby light", isOn: Binding(get: { light }, set: { model.setStandbyLight($0) }))
            }
            if let tone = settings.startupTone {
                Toggle("Startup sound", isOn: Binding(get: { tone }, set: { model.setStartupTone($0) }))
            }
        }
        }
        if settings.remoteEnabled != nil || settings.remoteVolumeStep != nil {
        Section("Remote") {
            if let remote = settings.remoteEnabled {
                Toggle("Respond to the remote", isOn: Binding(get: { remote }, set: { model.setRemoteEnabled($0) }))
            }
            if let step = settings.remoteVolumeStep {
                Stepper(value: Binding(get: { step }, set: { model.setRemoteVolumeStep($0) }), in: 1...10) {
                    HStack {
                        Text("Volume step")
                        Spacer()
                        Text("\(step)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("For the remote and the buttons on the speaker. The keyboard shortcuts' step is under General.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        }
    }

    private var firmwareSection: some View {
        Section("Firmware") {
            LabeledContent("Installed") {
                Text(model.firmware.map { shortFirmwareVersion($0) } ?? "—").foregroundStyle(.secondary)
            }
            LabeledContent("Status") {
                Text(model.firmwareStatusText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            if let progress = model.firmwareProgress {
                ProgressView(value: Double(min(max(progress, 0), 100)), total: 100)
            }
            HStack {
                if let notice = model.firmwareNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.firmwareActivity == .checking ? "Checking…" : "Check Now") { model.checkForFirmwareUpdate() }
                    .disabled(!model.isOnline || model.firmwareActivity != .idle || model.firmwareInstalling)
                if model.firmwareUpdateAvailable {
                    Button("Update…") { confirmingUpdate = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text("The speaker also checks for updates by itself every few hours and can install them while idle.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Helpers

    private var canRename: Bool { model.canRename(newName) }

    private func rename() {
        guard canRename else { return }
        pendingName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.rename(newName)
    }
}

/// A 0–100 volume setting that writes when the slider is released, not on every step.
private struct VolumeSettingRow: View {
    let title: String
    let value: Int
    /// The volume limit: the slider stops there.
    let ceiling: Int
    let commit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { draft ?? Double(min(value, ceiling)) }, set: { draft = $0.rounded() }),
                   in: 0...Double(max(ceiling, 1)), onEditingChanged: { editing in
                       if !editing, let draft {
                           if Int(draft) != value { commit(Int(draft)) }
                           self.draft = nil
                       }
                   })
            Text("\(Int(draft ?? Double(value)))").monospacedDigit().frame(width: 30, alignment: .trailing)
                .foregroundStyle(value > ceiling && draft == nil ? Color.orange : Color.primary)
                .help(value > ceiling ? "Stored above the volume limit (\(ceiling))" : "")
        }
    }
}
