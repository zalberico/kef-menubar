import Foundation
import Observation
import ServiceManagement

/// App preferences, persisted in UserDefaults.
@MainActor @Observable
final class Preferences {
    enum HostMode: String, CaseIterable, Identifiable {
        case automatic, manual
        var id: String { rawValue }
    }

    @ObservationIgnored private let defaults: UserDefaults

    var hostMode: HostMode { didSet { defaults.set(hostMode.rawValue, forKey: "hostMode") } }
    var manualHost: String { didSet { defaults.set(manualHost, forKey: "manualHost") } }
    /// Last address that worked in automatic mode (used at launch before discovery).
    var lastHost: String { didSet { defaults.set(lastHost, forKey: "lastHost") } }
    /// Speaker chosen among the discovered ones (its MAC address).
    var preferredSpeakerID: String { didSet { defaults.set(preferredSpeakerID, forKey: "preferredSpeakerID") } }
    var volumeStep: Int { didSet { defaults.set(volumeStep, forKey: "volumeStep") } }
    /// Speaker name, shown while (re)connecting.
    var lastSpeakerName: String { didSet { defaults.set(lastSpeakerName, forKey: "lastSpeakerName") } }
    /// Last input used, so the power button wakes the speaker on it even after a relaunch.
    var lastSource: String { didSet { if lastSource != oldValue { defaults.set(lastSource, forKey: "lastSource") } } }
    var showHUD: Bool { didSet { defaults.set(showHUD, forKey: "showHUD") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hostMode = HostMode(rawValue: defaults.string(forKey: "hostMode") ?? "") ?? .automatic
        manualHost = defaults.string(forKey: "manualHost") ?? ""
        lastHost = defaults.string(forKey: "lastHost") ?? ""
        preferredSpeakerID = defaults.string(forKey: "preferredSpeakerID") ?? ""
        let step = defaults.integer(forKey: "volumeStep")
        volumeStep = (1...10).contains(step) ? step : 2
        showHUD = defaults.object(forKey: "showHUD") as? Bool ?? true
        lastSpeakerName = defaults.string(forKey: "lastSpeakerName") ?? ""
        lastSource = defaults.string(forKey: "lastSource") ?? ""
    }

    func shortcut(for action: HotKeyAction) -> KeyCombo? {
        guard let data = defaults.data(forKey: "shortcut.\(action.rawValue)") else { return action.defaultCombo }
        return try? JSONDecoder().decode(KeyCombo?.self, from: data)
    }

    func setShortcut(_ combo: KeyCombo?, for action: HotKeyAction) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: "shortcut.\(action.rawValue)")
    }
}

/// Launch at login through SMAppService (the app registers itself as a login item).
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
