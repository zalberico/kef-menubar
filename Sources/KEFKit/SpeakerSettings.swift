import Foundation

// The speaker's own settings that KEF Connect exposes on its settings screens:
// name, auto-standby and wake source, startup volume, standby light, startup tone,
// the IR remote and its volume step, and switching to TV when the TV turns on.
// All are plain values under `settings:/`, written with `setData` like the volume.

/// `settings:/kef/host/standbyMode`. KEF Connect calls the 20-minute mode "ECO".
public enum StandbyMode: String, Sendable, CaseIterable, Identifiable {
    case eco = "standby_20mins"
    case thirtyMinutes = "standby_30mins"
    case sixtyMinutes = "standby_60mins"
    case never = "standby_none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .eco: "ECO (20 minutes)"
        case .thirtyMinutes: "30 minutes"
        case .sixtyMinutes: "60 minutes"
        case .never: "Never"
        }
    }

    /// ECO standby is only available with the default wake source (as in KEF Connect).
    /// `wakeRaw` is the speaker's `wakeUpSource` value, `nil` if it has no such setting.
    public func isAllowed(wakeRaw: String?) -> Bool {
        self != .eco || wakeRaw == nil || wakeRaw == WakeSource.automatic.rawValue
    }
}

/// `settings:/kef/host/wakeUpSource` (`kefWakeUpSource`): which input's signal wakes the
/// speaker from standby. Network sources (Wi-Fi, AirPlay) always wake it.
public enum WakeSource: String, Sendable, CaseIterable, Identifiable {
    case automatic = "wakeup_default"
    case bluetooth
    case usb
    case optical
    case coaxial
    case analog
    case tv

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Default"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .optical: "Optical"
        case .coaxial: "Coaxial"
        case .analog: "Analog"
        case .tv: "TV"
        }
    }

    /// The wake sources that make sense for a list of inputs (always including the default).
    public static func options(for inputs: [Source]) -> [WakeSource] {
        allCases.filter { wake in
            switch wake {
            case .automatic: true
            case .bluetooth: inputs.contains(.bluetooth)
            case .usb: inputs.contains(.usb)
            case .optical: inputs.contains(.optical)
            case .coaxial: inputs.contains(.coaxial)
            case .analog: inputs.contains(.analog)
            case .tv: inputs.contains(.tv)
            }
        }
    }
}

/// A snapshot of the speaker settings. A field is `nil` when this speaker doesn't report it.
public struct SpeakerSettings: Sendable, Equatable {
    public var standbyMode: StandbyMode?
    /// The speaker's `wakeUpSource` value as read (kept even if this app doesn't know it).
    public var wakeSourceRaw: String?
    public var wakeSource: WakeSource? { wakeSourceRaw.flatMap(WakeSource.init(rawValue:)) }
    /// Reset the volume to a startup level when the speaker goes to standby.
    public var startupVolumeEnabled: Bool?
    /// One startup level per input instead of one for all.
    public var startupVolumePerInput: Bool?
    public var startupVolume: Int?
    public var startupVolumes: [Source: Int] = [:]
    /// The front light while in standby (stored inverted, as `disableFrontStandbyLED`).
    public var standbyLight: Bool?
    public var startupTone: Bool?
    /// Whether the speaker listens to the IR remote.
    public var remoteEnabled: Bool?
    /// Volume change per press of the remote or the speaker's buttons, 1–10.
    public var remoteVolumeStep: Int?
    /// Switch to the TV input when the TV turns on.
    public var autoSwitchToTV: Bool?

    public init() {}

    /// Nothing could be read (the speaker didn't answer, or has none of these settings).
    public var isEmpty: Bool {
        standbyMode == nil && wakeSourceRaw == nil && startupVolumeEnabled == nil && startupVolumePerInput == nil
            && startupVolume == nil && startupVolumes.isEmpty && standbyLight == nil && startupTone == nil
            && remoteEnabled == nil && remoteVolumeStep == nil && autoSwitchToTV == nil
    }

    /// The startup volume setting of each input, by path.
    public static func startupVolumePath(_ source: Source) -> String? {
        switch source {
        case .wifi: "settings:/kef/host/defaultVolumeWifi"
        case .bluetooth: "settings:/kef/host/defaultVolumeBluetooth"
        case .optical: "settings:/kef/host/defaultVolumeOptical"
        case .coaxial: "settings:/kef/host/defaultVolumeCoaxial"
        case .usb: "settings:/kef/host/defaultVolumeUSB"
        case .analog: "settings:/kef/host/defaultVolumeAnalogue"
        case .tv: "settings:/kef/host/defaultVolumeTV"
        case .standby: nil
        }
    }
}

extension KEFPath {
    public static let deviceNameChangeCount = "settings:/deviceNameChangeCount"
    public static let standbyMode = "settings:/kef/host/standbyMode"
    public static let wakeUpSource = "settings:/kef/host/wakeUpSource"
    public static let startupVolumeEnabled = "settings:/kef/host/standbyDefaultVol"
    public static let startupVolumePerInput = "settings:/kef/host/advancedStandbyDefaultVol"
    public static let startupVolume = "settings:/kef/host/defaultVolumeGlobal"
    public static let disableStandbyLight = "settings:/kef/host/disableFrontStandbyLED"
    public static let startupTone = "settings:/kef/host/startupTone"
    public static let remoteIR = "settings:/kef/host/remote/remoteIR"
    public static let autoSwitchToTV = "settings:/kef/host/autoSwitchToHDMI"
    /// KEF Connect's action for setting a startup volume; the `defaultVolume*` settings above
    /// are where it is read back.
    public static let startupVolumeSet = "hostlink:defaultVolume/set"
}

extension KEFClient {
    /// Read every speaker setting (concurrently); settings this speaker doesn't have stay `nil`.
    public func speakerSettings(inputs: [Source]) async -> SpeakerSettings {
        async let standby = try? getValue(KEFPath.standbyMode).string.flatMap(StandbyMode.init(rawValue:))
        async let wake = try? getValue(KEFPath.wakeUpSource).string
        async let enabled = try? getValue(KEFPath.startupVolumeEnabled).bool
        async let perInput = try? getValue(KEFPath.startupVolumePerInput).bool
        async let global = try? getValue(KEFPath.startupVolume).int
        async let disableLight = try? getValue(KEFPath.disableStandbyLight).bool
        async let tone = try? getValue(KEFPath.startupTone).bool
        async let remote = try? getValue(KEFPath.remoteIR).bool
        async let step = try? getValue(KEFPath.volumeStep).int
        async let autoTV = try? getValue(KEFPath.autoSwitchToTV).bool
        let perSource = await withTaskGroup(of: (Source, Int?).self) { group in
            for source in inputs {
                guard let path = SpeakerSettings.startupVolumePath(source) else { continue }
                group.addTask { (source, try? await getValue(path).int) }
            }
            var result: [Source: Int] = [:]
            for await (source, level) in group { if let level { result[source] = level } }
            return result
        }

        var settings = SpeakerSettings()
        settings.standbyMode = await standby ?? nil
        settings.wakeSourceRaw = await wake ?? nil
        settings.startupVolumeEnabled = await enabled ?? nil
        settings.startupVolumePerInput = await perInput ?? nil
        settings.startupVolume = await global ?? nil
        settings.startupVolumes = perSource
        settings.standbyLight = (await disableLight ?? nil).map { !$0 }
        settings.startupTone = await tone ?? nil
        settings.remoteEnabled = await remote ?? nil
        settings.remoteVolumeStep = await step ?? nil
        settings.autoSwitchToTV = await autoTV ?? nil
        return settings
    }

    /// Rename the speaker (also its AirPlay and Spotify Connect name).
    public func setDeviceName(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KEFError.invalidValue("the speaker name can't be empty") }
        guard trimmed.count <= 64 else { throw KEFError.invalidValue("the speaker name is too long (64 characters at most)") }
        try await setValue(KEFPath.deviceName, type: ValueType.string, .string(trimmed))
    }

    public func setStandbyMode(_ mode: StandbyMode) async throws {
        try await setValue(KEFPath.standbyMode, type: "kefStandbyMode", .string(mode.rawValue))
    }

    public func setWakeSource(_ source: WakeSource) async throws {
        try await setValue(KEFPath.wakeUpSource, type: "kefWakeUpSource", .string(source.rawValue))
    }

    public func setStartupVolumeEnabled(_ enabled: Bool) async throws {
        try await setValue(KEFPath.startupVolumeEnabled, type: ValueType.bool, .bool(enabled))
    }

    public func setStartupVolumePerInput(_ perInput: Bool) async throws {
        try await setValue(KEFPath.startupVolumePerInput, type: ValueType.bool, .bool(perInput))
    }

    /// Startup volume for all inputs, or for one input with `source`, then read back: throws
    /// if the speaker didn't store exactly that level, so the app never shows a level the
    /// speaker won't use.
    ///
    /// One input goes through KEF Connect's action (`hostlink:defaultVolume/set`). The level for
    /// all inputs is written to `defaultVolumeGlobal` directly: on firmware 3.1.141 the action
    /// with no input is accepted but changes nothing.
    public func setStartupVolume(_ level: Int, for source: Source? = nil) async throws {
        guard (0...100).contains(level) else { throw KEFError.invalidValue("startup volume must be 0–100") }
        let readBack: String
        if let source {
            guard let path = SpeakerSettings.startupVolumePath(source) else {
                throw KEFError.invalidValue("no startup volume for \(source.rawValue)")
            }
            readBack = path
            var body = JSONObject()
            body["kefPhysicalSource"] = .string(source.rawValue)
            body["defaultVolume"] = .int(Int64(level))
            // The one way past KEFSafety for `hostlink:` (blocked for generic writes).
            _ = try await transport.request(.setData(KEFPath.startupVolumeSet, .typed("kefDefaultVolumeSettings", .object(body)),
                                                     role: "activate"))
        } else {
            readBack = KEFPath.startupVolume
            try await setValue(KEFPath.startupVolume, type: ValueType.i32, .int(Int64(level)))
        }
        let stored = try await getValue(readBack).int
        guard stored == level else {
            throw KEFError.invalidResponse("the speaker kept startup volume \(stored.map(String.init) ?? "?") instead of \(level)")
        }
    }

    public func setStandbyLight(_ on: Bool) async throws {
        try await setValue(KEFPath.disableStandbyLight, type: ValueType.bool, .bool(!on))
    }

    public func setStartupTone(_ on: Bool) async throws {
        try await setValue(KEFPath.startupTone, type: ValueType.bool, .bool(on))
    }

    public func setRemoteEnabled(_ on: Bool) async throws {
        try await setValue(KEFPath.remoteIR, type: ValueType.bool, .bool(on))
    }

    public func setRemoteVolumeStep(_ step: Int) async throws {
        guard (1...10).contains(step) else { throw KEFError.invalidValue("volume step must be 1–10") }
        try await setValue(KEFPath.volumeStep, type: ValueType.i16, .int(Int64(step)))
    }

    public func setAutoSwitchToTV(_ on: Bool) async throws {
        try await setValue(KEFPath.autoSwitchToTV, type: ValueType.bool, .bool(on))
    }
}

// MARK: - Subwoofer presets

/// KEF subwoofer models and the settings KEF Connect applies when you pick one: sub gain,
/// sub crossover (low-pass) and the speakers' high-pass, which depend on whether the sub is
/// connected with a KW1 wireless kit and on how many subs there are.
///
/// Values from KEF Connect's tables, as extracted by the homeassistant-kef project
/// (https://github.com/EvotecIT/homeassistant-kef, MIT) for the XIO, LSX II and LSX II LT.
public enum SubwooferPreset: String, Sendable, CaseIterable, Identifiable {
    case kc62
    case kf92
    case kube8b
    case kube10b
    case kube12b
    case kube15mie
    case t2

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .kc62: "KEF KC62"
        case .kf92: "KEF KF92 / KC92"
        case .kube8b: "KEF Kube 8b / 8 MIE"
        case .kube10b: "KEF Kube 10b / 10 MIE"
        case .kube12b: "KEF Kube 12b / 12 MIE"
        case .kube15mie: "KEF Kube 15 MIE"
        case .t2: "KEF T2"
        }
    }

    public struct Values: Sendable, Equatable {
        public var gain: Double
        public var crossover: Double
        public var highPass: Double
    }

    /// Product codes (`settings:/kef/host/modelName`) these tables are known to apply to.
    public static let supportedModels: Set<String> = ["SP4041", "SP4077"]  // LSX II, LSX II LT

    /// The defaults for this sub, or `nil` for an untabulated combination.
    public func values(kw1: Bool, count: Int) -> Values? {
        // (gain, crossover, high-pass) for (no KW1, 1 sub), (no KW1, 2 subs), (KW1, 1 sub), (KW1, 2 subs).
        let table: [(Double, Double, Double)?]
        switch self {
        case .kc62: table = [(-1, 55, 67.5), (-7, 55, 67.5), (4, 55, 67.5), (-2, 55, 67.5)]
        case .kf92: table = [(-3, 55, 67.5), (-9, 55, 67.5), (2, 55, 67.5), (-4, 55, 67.5)]
        case .kube8b: table = [(3, 62.5, 67.5), (-3, 62.5, 67.5), (2, 62.5, 67.5), (-4, 62.5, 67.5)]
        case .kube10b: table = [(1, 55, 67.5), (-5, 55, 67.5), (0, 55, 67.5), (-6, 55, 67.5)]
        case .kube12b: table = [(-1, 52.5, 65), (-7, 52.5, 65), (-2, 52.5, 65), (-8, 52.5, 65)]
        case .kube15mie: table = [(0, 57.5, 65), (-6, 57.5, 65), (-1, 57.5, 65), (-7, 57.5, 65)]
        case .t2: table = [(-1, 62.5, 67.5), (-7, 62.5, 67.5), nil, nil]
        }
        guard count == 1 || count == 2, let entry = table[(kw1 ? 2 : 0) + count - 1] else { return nil }
        return Values(gain: entry.0, crossover: entry.1, highPass: entry.2)
    }
}

extension EqProfile {
    /// The sub model chosen in the profile, if it's one with known defaults.
    public var subwooferPreset: SubwooferPreset? { string(.subwooferPreset).flatMap(SubwooferPreset.init(rawValue:)) }

    /// The defaults of `preset` for this profile's sub setup (KW1 kit, number of subs).
    public func presetValues(_ preset: SubwooferPreset) -> SubwooferPreset.Values? {
        preset.values(kw1: raw["isKW1"]?.bool ?? false, count: self[.subwooferCount]?.int ?? 1)
    }

    /// This profile with `preset` chosen and its gain, crossover and high-pass applied, as
    /// KEF Connect does. `nil` if there are no known values for this setup.
    public func applying(_ preset: SubwooferPreset) -> EqProfile? {
        guard let values = presetValues(preset) else { return nil }
        var profile = self
        profile.set(.subwooferPreset, preset.rawValue)
        profile.set(.subwooferGain, values.gain)
        profile.set(.subOutLPFreq, values.crossover)
        profile.set(.highPassModeFreq, values.highPass)
        return profile
    }

    /// Whether the gain, crossover and high-pass are the chosen sub's defaults.
    public var isAtPresetDefaults: Bool {
        guard let preset = subwooferPreset, let values = presetValues(preset) else { return true }
        func same(_ key: EqKey, _ value: Double) -> Bool { abs((double(key) ?? .nan) - value) < 0.01 }
        return same(.subwooferGain, values.gain) && same(.subOutLPFreq, values.crossover)
            && same(.highPassModeFreq, values.highPass)
    }
}
