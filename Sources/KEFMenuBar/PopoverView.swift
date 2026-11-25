import KEFKit
import SwiftUI

struct PopoverView: View {
    @Environment(SpeakerModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WindowHeightPinner(height: contentHeight))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView()
            if model.isOnline {
                VolumeRow()
                    .disabled(!model.isOn || model.inputSettling)
                InputGrid()
                if model.showsNowPlaying {
                    NowPlayingView()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if model.eq?.hasSubwoofer == true {
                    SubwooferRow()
                        .disabled(!model.isOn || model.inputSettling)
                }
                if model.eq != nil {
                    SoundSection()
                        .disabled(!model.isOn || model.inputSettling)
                }
            } else {
                OfflineView()
            }
            FooterView()
        }
        .padding(16)
        .frame(width: 330)
        .animation(.snappy(duration: 0.25), value: model.showsNowPlaying)
        .animation(.snappy(duration: 0.25), value: model.isOnline)
    }
}

/// MenuBarExtra grows its window when the content grows but never shrinks it, so a
/// shorter view (offline, Sound collapsed) would float in a tall transparent window.
/// Resize the window to the content, keeping its top edge under the menu bar.
private struct WindowHeightPinner: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard height > 0 else { return }
        DispatchQueue.main.async {
            guard let window = view.window, abs(window.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: SpeakerGlyph.image(model.isOn ? .on : (model.isOnline ? .standby : .offline), height: 20))
                .renderingMode(.template)
                .foregroundStyle(model.isOn ? Color.accentColor : .secondary)
                .frame(width: 36, height: 36)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                    Text(model.statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            PowerButton()
        }
    }

    private var dotColor: Color {
        switch model.connection {
        case .online: model.isOn ? .green : .orange
        case .offline: .red
        default: .secondary
        }
    }
}

private struct PowerButton: View {
    @Environment(SpeakerModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button(action: model.togglePower) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(model.isOn ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(model.isOn ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.7))))
        }
        .buttonStyle(.plain)
        .disabled(!model.isOnline)
        .onHover { hovering = $0 }
        .help(model.isOn ? "Standby" : "Turn on (\(model.lastSource.displayName))")
        .accessibilityLabel(model.isOn ? "Put speaker in standby" : "Turn speaker on")
    }
}

// MARK: - Volume

private struct VolumeRow: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleMute) {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.muted ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(model.muted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { Double(model.volume) },
                    set: { model.setVolume(Int($0.rounded())) }),
                in: 0...Double(model.volumeCeiling))
                .controlSize(.small)
                .opacity(model.muted ? 0.5 : 1)
                .accessibilityLabel("Volume")

            Text("\(model.volume)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

// MARK: - Inputs

private struct InputGrid: View {
    @Environment(SpeakerModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    /// The model's inputs, plus whatever input the speaker reports if it isn't one of them.
    private var sources: [Source] {
        var sources = Source.inputs(forModel: model.modelName)
        if model.isOn, let current = model.source, !sources.contains(current) { sources.append(current) }
        return sources
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(sources) { source in
                InputTile(source: source, selected: model.isOn && model.source == source) {
                    model.select(source)
                }
            }
        }
    }
}

private struct InputTile: View {
    let source: Source
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: source.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(source.shortName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.quaternary.opacity(hovering ? 1 : 0.55))))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(source.helpText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Source {
    var symbol: String {
        switch self {
        case .usb: "macmini.fill"
        case .wifi: "airplay.audio"
        case .tv: "tv"
        case .optical: "rays"
        case .analog: "waveform.path"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .coaxial: "cable.coaxial"
        case .standby: "power"
        }
    }

    var shortName: String { self == .wifi ? "Wi-Fi" : displayName }

    var helpText: String {
        switch self {
        case .usb: "USB-C (this Mac)"
        case .wifi: "Wi-Fi: AirPlay, Chromecast, Spotify Connect…"
        case .tv: "TV (HDMI eARC)"
        default: displayName
        }
    }
}

// MARK: - Now playing

private struct NowPlayingView: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.player.track?.title ?? "")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text([model.player.track?.artist, model.player.track?.album].compactMap { $0 }.joined(separator: " — "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                TransportButton(symbol: "backward.fill", enabled: model.player.canPrevious) { model.control(.previous) }
                TransportButton(symbol: model.player.isPlaying ? "pause.fill" : "play.fill", enabled: model.player.canPause, large: true) {
                    model.control(.pause)
                }
                TransportButton(symbol: "forward.fill", enabled: model.player.canNext) { model.control(.next) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct TransportButton: View {
    let symbol: String
    let enabled: Bool
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 16 : 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}

// MARK: - Subwoofer & sound

private struct SubwooferRow: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        ValueSlider(
            title: "Subwoofer", systemImage: "circle.circle.fill",
            value: model.eq?.double(.subwooferGain) ?? 0, range: model.range(.subwooferGain),
            format: Fmt.signedDB
        ) { value in model.updateEQ { $0.set(.subwooferGain, value) } }
    }
}

private struct SoundSection: View {
    @Environment(SpeakerModel.self) private var model
    @AppStorage("soundExpanded") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Sound")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let name = model.eq?.string(.profileName), !name.isEmpty {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let eq = model.eq {
                SoundControls(eq: eq)
                    .transition(.opacity)
            }
        }
    }
}

private struct SoundControls: View {
    @Environment(SpeakerModel.self) private var model
    let eq: EqProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ValueSlider(title: "Treble", value: eq.double(.trebleAmount) ?? 0, range: model.range(.trebleAmount),
                        format: Fmt.signedDB) { v in model.updateEQ { $0.set(.trebleAmount, v) } }

            LabeledRow("Bass extension") {
                Picker("Bass extension", selection: Binding(
                    get: { eq.string(.bassExtension) ?? "standard" },
                    set: { v in model.updateEQ { $0.set(.bassExtension, v) } })
                ) {
                    Text("Less").tag("less")
                    Text("Standard").tag("standard")
                    Text("Extra").tag("extra")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            ToggleSlider(title: "Desk mode", key: .deskMode, settingKey: .deskModeSetting, eq: eq)
            ToggleSlider(title: "Wall mode", key: .wallMode, settingKey: .wallModeSetting, eq: eq)

            ValueSlider(title: "Balance", value: eq.double(.balance) ?? 0, range: model.range(.balance),
                        format: Fmt.balance) { v in model.updateEQ { $0[.balance] = .int(Int64(v)) } }

            BoolRow(title: "Phase correction", key: .phaseCorrection, eq: eq)

            Divider().padding(.vertical, 2)
            SubwooferCountRow(eq: eq)

            if eq.hasSubwoofer {
                if model.offersSubwooferPresets {
                    SubwooferPresetRow(eq: eq)
                }
                ValueSlider(title: "Sub crossover", value: eq.double(.subOutLPFreq) ?? 80, range: model.range(.subOutLPFreq),
                            format: Fmt.hertz) { v in model.updateEQ { $0.set(.subOutLPFreq, v) } }
            }
            // Always reachable: with no sub it should normally be off (full-range speakers).
            ToggleSlider(title: "Speaker high-pass", key: .highPassMode, settingKey: .highPassModeFreq, eq: eq, format: Fmt.hertz)
            if eq.hasSubwoofer {
                LabeledRow("Sub polarity") {
                    Picker("Sub polarity", selection: Binding(
                        get: { eq.string(.subwooferPolarity) ?? "normal" },
                        set: { v in model.updateEQ { $0.set(.subwooferPolarity, v) } })
                    ) {
                        Text("Normal").tag("normal")
                        Text("Inverted").tag("inverted")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                BoolRow(title: "Subwoofer output", key: .subwooferOut, eq: eq)
            }

            Text(model.isOn
                 ? "Applies to the \(model.source?.displayName ?? "current") input's profile. The speaker keeps one per input."
                 : "Turn the speaker on to change its sound. The speaker keeps one profile per input.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How many wired subwoofers this input's profile drives. The sub level and sub settings
/// only show once there is at least one.
private struct SubwooferCountRow: View {
    @Environment(SpeakerModel.self) private var model
    let eq: EqProfile

    var body: some View {
        let maxCount = max(1, Int(model.range(.subwooferCount).max.rounded()))
        LabeledRow("Subwoofers") {
            Picker("Subwoofers", selection: Binding(
                get: { eq.subwooferCount },
                set: { n in model.updateEQ { $0.setSubwooferCount(n) } })
            ) {
                Text("None").tag(0)
                ForEach(1...maxCount, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

/// The sub model (KEF Connect's presets) and a way back to its default gain, crossover and
/// high-pass after manual tweaks.
private struct SubwooferPresetRow: View {
    @Environment(SpeakerModel.self) private var model
    let eq: EqProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledRow("Sub model") {
                Picker("Sub model", selection: Binding(
                    get: { eq.string(.subwooferPreset) ?? "" },
                    set: { raw in if let preset = SubwooferPreset(rawValue: raw) { model.applySubwooferPreset(preset) } })
                ) {
                    ForEach(SubwooferPreset.allCases) { Text($0.title).tag($0.rawValue) }
                    if eq.subwooferPreset == nil {
                        Text("Other").tag(eq.string(.subwooferPreset) ?? "")
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            if let preset = eq.subwooferPreset, let values = eq.presetValues(preset), !eq.isAtPresetDefaults {
                HStack(spacing: 6) {
                    Text("Defaults: \(Fmt.signedDB(values.gain)), \(Fmt.hertz(values.crossover)), high-pass \(Fmt.hertz(values.highPass))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button("Restore") { model.applySubwooferPreset(preset) }
                        .controlSize(.small)
                        .help("Set the sub gain, crossover and speaker high-pass back to the \(preset.title) defaults")
                }
            }
        }
    }
}

private struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 104, alignment: .leading)
            content
        }
    }
}

private struct BoolRow: View {
    @Environment(SpeakerModel.self) private var model
    let title: String
    let key: EqKey
    let eq: EqProfile

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Toggle(title, isOn: Binding(get: { eq.bool(key) ?? false }, set: { v in model.updateEQ { $0.set(key, v) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// A switch with the slider that tunes it (desk / wall mode dB, high-pass Hz).
private struct ToggleSlider: View {
    @Environment(SpeakerModel.self) private var model
    let title: String
    let key: EqKey
    let settingKey: EqKey
    let eq: EqProfile
    var format: (Double) -> String = Fmt.signedDB

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoolRow(title: title, key: key, eq: eq)
            if eq.bool(key) == true {
                ValueSlider(title: "", value: eq.double(settingKey) ?? 0, range: model.range(settingKey), format: format) { v in
                    model.updateEQ { $0.set(settingKey, v) }
                }
            }
        }
    }
}

/// Label, slider snapped to the speaker's step, and the formatted value.
private struct ValueSlider: View {
    let title: String
    var systemImage: String?
    let value: Double
    let range: EqRange
    let format: (Double) -> String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Always reserve the label column so every slider lines up.
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 12))
            }
            .frame(width: 104, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { raw in
                let snapped = range.snap(raw)
                if snapped != value { onChange(snapped) }
            }), in: range.closed)
            .controlSize(.mini)
            Text(format(value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

enum Fmt {
    static func signedDB(_ v: Double) -> String {
        let number = v.rounded() == v ? String(Int(v)) : String(format: "%g", v)
        return v > 0 ? "+\(number) dB" : (v == 0 ? "0 dB" : "\(number.replacingOccurrences(of: "-", with: "−")) dB")
    }

    static func hertz(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v)) Hz" : String(format: "%.1f Hz", v)
    }

    static func balance(_ v: Double) -> String {
        let steps = Int(v)
        return steps == 0 ? "Center" : (steps < 0 ? "L \(-steps)" : "R \(steps)")
    }
}

// MARK: - Offline & footer

private struct OfflineView: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if case .offline(let reason) = model.connection {
                Image(nsImage: SpeakerGlyph.image(.offline, height: 30))
                    .renderingMode(.template)
                    .foregroundStyle(.secondary)
                Text("Can't reach the speaker")
                    .font(.system(size: 13, weight: .semibold))
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Retry Now") { model.reconnect(rediscover: model.preferences.hostMode == .automatic) }
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                ProgressView().controlSize(.small)
                Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

private struct FooterView: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if model.firmwareActivity == .updating || (model.isOnline && model.firmwareInstalling) {
                Label("Updating firmware. Keep the speaker plugged in; it restarts when done.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.firmwareUpdateAvailable {
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label("Firmware update available", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
    }
}
