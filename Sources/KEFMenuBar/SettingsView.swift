import KEFKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(SpeakerModel.self) private var model
    @State private var manualHost = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginStatus = LaunchAtLogin.status
    @State private var loginError: String?
    @State private var maximumVolume = 100

    private var prefs: Preferences { model.preferences }

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("Speaker") {
                Picker("Connection", selection: Binding(
                    get: { prefs.hostMode },
                    set: { mode in
                        // Switching to manual keeps the speaker we are connected to.
                        if mode == .manual, prefs.manualHost.isEmpty, let host = model.host {
                            prefs.manualHost = host
                            manualHost = host
                        }
                        prefs.hostMode = mode
                        model.reconnect()
                    })
                ) {
                    Text("Find automatically (Bonjour)").tag(Preferences.HostMode.automatic)
                    Text("Manual IP address").tag(Preferences.HostMode.manual)
                }

                if prefs.hostMode == .automatic {
                    discoveredList
                } else {
                    HStack {
                        TextField("IP address", text: $manualHost, prompt: Text("192.168.1.78"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(applyManualHost)
                        Button("Connect", action: applyManualHost)
                            .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                LabeledContent("Status") {
                    Text(connectionSummary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }

            Section("Volume") {
                Stepper(value: $prefs.volumeStep, in: 1...10) {
                    HStack {
                        Text("Shortcut volume step")
                        Spacer()
                        Text("\(prefs.volumeStep)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Toggle("Limit maximum volume", isOn: Binding(
                    get: { model.volumeLimited }, set: { model.setVolumeLimited($0) }))
                    .disabled(!model.isOnline)
                HStack {
                    Text("Maximum volume")
                    Slider(value: Binding(
                        get: { Double(maximumVolume) },
                        set: { maximumVolume = Int($0.rounded()) }),
                           in: 1...100, onEditingChanged: { editing in
                               if !editing, maximumVolume != model.maximumVolume { model.setMaximumVolume(maximumVolume) }
                           })
                    Text("\(maximumVolume)").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
                .disabled(!model.isOnline)
                Toggle("Show volume overlay for shortcuts", isOn: $prefs.showHUD)
            }

            Section("Keyboard shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    Text("Approve KEF Menu Bar in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Text("The speaker checks for firmware updates on its own. To update right away, use the KEF Connect app. This app never updates firmware, resets, reboots or reconfigures the speaker's network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            manualHost = prefs.manualHost.isEmpty ? (model.host ?? "") : prefs.manualHost
            maximumVolume = model.maximumVolume
            refreshLoginStatus()
            if prefs.hostMode == .automatic, model.discovered.isEmpty, !model.isDiscovering {
                Task { await model.discover() }
            }
        }
        .onChange(of: model.maximumVolume) { _, value in maximumVolume = value }
    }

    @ViewBuilder private var discoveredList: some View {
        if model.discovered.isEmpty {
            HStack {
                Text(model.isDiscovering ? "Searching…" : "No speakers found yet")
                    .foregroundStyle(.secondary)
                Spacer()
                scanButton
            }
        } else {
            ForEach(model.discovered) { speaker in
                HStack {
                    Image(systemName: speaker.host == model.host ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(speaker.host == model.host ? Color.accentColor : .secondary)
                    VStack(alignment: .leading) {
                        Text(speaker.name)
                        Text("\(speaker.modelName ?? speaker.model ?? "KEF") · \(speaker.host)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if speaker.host != model.host {
                        Button("Use") {
                            prefs.preferredSpeakerID = speaker.id
                            prefs.lastHost = speaker.host
                            model.reconnect(rediscover: false)
                        }
                    }
                }
            }
            HStack { Spacer(); scanButton }
        }
    }

    private var scanButton: some View {
        Button(model.isDiscovering ? "Scanning…" : "Scan") { Task { await model.discover() } }
            .disabled(model.isDiscovering)
    }

    private var connectionSummary: String {
        switch model.connection {
        case .online:
            let scheme = model.isSecure == false ? "HTTP" : "HTTPS"
            var parts = ["\(model.modelName.map(modelDisplay) ?? model.name) at \(model.host ?? "?") (\(scheme))"]
            if let firmware = model.firmware { parts.append("Firmware \(firmware.split(separator: ".").prefix(3).joined(separator: "."))") }
            return parts.joined(separator: "\n")
        case .connecting(let host): return "Connecting to \(host)…"
        case .searching: return "Searching…"
        case .offline(let reason): return reason
        }
    }

    private func modelDisplay(_ code: String) -> String {
        ["SP4041": "LSX II", "SP4077": "LSX II LT", "SP4025": "LS50 Wireless II", "SP4033": "LS60 Wireless"][code] ?? code
    }

    private func applyManualHost() {
        let host = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        prefs.manualHost = host
        model.reconnect(rediscover: false)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        loginStatus = LaunchAtLogin.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
    }
}

/// Click, then press a shortcut (⌫ clears it, ⎋ cancels). Only one records at a time.
struct ShortcutRecorder: View {
    @Environment(SpeakerModel.self) private var model
    let action: HotKeyAction

    private var center: HotKeyCenter { .shared }

    var body: some View {
        _ = center.revision  // re-read shortcuts and availability when registrations change
        let combo = model.preferences.shortcut(for: action)
        let recording = center.recordingAction == action
        let unavailable = combo != nil && center.recordingAction == nil && !center.isRegistered(action)
        return HStack(spacing: 6) {
            if unavailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut is taken by another app or by macOS.")
            }
            Button {
                recording ? center.endRecording() : center.beginRecording(action) { save($0) }
            } label: {
                Text(recording ? "Type shortcut…" : (combo?.display ?? "None"))
                    .font(.system(size: 12, weight: .medium).monospaced())
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if combo != action.defaultCombo {
                Button("Reset") { save(action.defaultCombo); center.registerAll?() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .onDisappear { if center.recordingAction == action { center.endRecording() } }
    }

    /// Save `combo` for this action, taking it away from any other action that had it.
    private func save(_ combo: KeyCombo?) {
        let preferences = model.preferences
        if let combo {
            for other in HotKeyAction.allCases where other != action && preferences.shortcut(for: other) == combo {
                preferences.setShortcut(nil, for: other)
            }
        }
        preferences.setShortcut(combo, for: action)
    }
}
