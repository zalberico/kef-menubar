import Foundation
import Observation

/// The UserDefaults keys shared by ``Preferences`` and ``SharedSpeakerConfig``.
public enum PreferenceKey {
    public static let hostMode = "hostMode"
    public static let manualHost = "manualHost"
    public static let lastHost = "lastHost"
    public static let preferredSpeakerID = "preferredSpeakerID"
    public static let volumeStep = "volumeStep"
    public static let lastSpeakerName = "lastSpeakerName"
    public static let lastSource = "lastSource"
    public static let showHUD = "showHUD"
    public static let lastModelCode = "lastModelCode"
    public static let lastIsSecure = "lastIsSecure"
    public static let knownSpeakers = "knownSpeakers"

    /// The app's volume step (keyboard shortcuts on the Mac, buttons and intents on iOS).
    public static let volumeStepRange = 1...10
    public static let defaultVolumeStep = 2

    /// A stored step, or the default when it is missing or out of range.
    public static func volumeStep(_ stored: Int) -> Int {
        volumeStepRange.contains(stored) ? stored : defaultVolumeStep
    }
}

/// A speaker this app has connected to, so it can be offered again later.
public struct SavedSpeaker: Codable, Sendable, Hashable, Identifiable {
    /// The speaker's MAC address in automatic mode (``KEFKit/DiscoveredSpeaker/id``), else its address.
    public var id: String
    public var name: String
    public var host: String
    /// Product code, e.g. `SP4041`.
    public var modelCode: String?

    public init(id: String, name: String, host: String, modelCode: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.modelCode = modelCode
    }
}

/// App preferences, persisted in UserDefaults (the standard domain on the Mac, an App Group
/// suite on iOS so the widgets and intents can read them).
@MainActor @Observable
public final class Preferences {
    public enum HostMode: String, CaseIterable, Identifiable, Sendable {
        case automatic, manual
        public var id: String { rawValue }
    }

    @ObservationIgnored public let defaults: UserDefaults

    public var hostMode: HostMode { didSet { defaults.set(hostMode.rawValue, forKey: PreferenceKey.hostMode) } }
    public var manualHost: String { didSet { defaults.set(manualHost, forKey: PreferenceKey.manualHost) } }
    /// Last address that worked in automatic mode (used at launch before discovery).
    public var lastHost: String { didSet { defaults.set(lastHost, forKey: PreferenceKey.lastHost) } }
    /// Speaker chosen among the discovered ones (its MAC address).
    public var preferredSpeakerID: String { didSet { defaults.set(preferredSpeakerID, forKey: PreferenceKey.preferredSpeakerID) } }
    public var volumeStep: Int { didSet { defaults.set(volumeStep, forKey: PreferenceKey.volumeStep) } }
    /// Speaker name, shown while (re)connecting.
    public var lastSpeakerName: String { didSet { defaults.set(lastSpeakerName, forKey: PreferenceKey.lastSpeakerName) } }
    /// Last input used, so the power button wakes the speaker on it even after a relaunch.
    public var lastSource: String { didSet { if lastSource != oldValue { defaults.set(lastSource, forKey: PreferenceKey.lastSource) } } }
    public var showHUD: Bool { didSet { defaults.set(showHUD, forKey: PreferenceKey.showHUD) } }
    /// Product code of the speaker last connected to (which inputs it has), e.g. `SP4041`.
    public var lastModelCode: String {
        didSet { if lastModelCode != oldValue { defaults.set(lastModelCode, forKey: PreferenceKey.lastModelCode) } }
    }
    /// Whether that speaker answered over HTTPS; `nil` until known.
    public var lastIsSecure: Bool? {
        didSet {
            guard lastIsSecure != oldValue else { return }
            if let lastIsSecure {
                defaults.set(lastIsSecure, forKey: PreferenceKey.lastIsSecure)
            } else {
                defaults.removeObject(forKey: PreferenceKey.lastIsSecure)
            }
        }
    }
    /// Speakers connected to before, most recent first.
    public var knownSpeakers: [SavedSpeaker] {
        didSet {
            guard knownSpeakers != oldValue else { return }
            defaults.set(try? JSONEncoder().encode(knownSpeakers), forKey: PreferenceKey.knownSpeakers)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hostMode = HostMode(rawValue: defaults.string(forKey: PreferenceKey.hostMode) ?? "") ?? .automatic
        manualHost = defaults.string(forKey: PreferenceKey.manualHost) ?? ""
        lastHost = defaults.string(forKey: PreferenceKey.lastHost) ?? ""
        preferredSpeakerID = defaults.string(forKey: PreferenceKey.preferredSpeakerID) ?? ""
        volumeStep = PreferenceKey.volumeStep(defaults.integer(forKey: PreferenceKey.volumeStep))
        showHUD = defaults.object(forKey: PreferenceKey.showHUD) as? Bool ?? true
        lastSpeakerName = defaults.string(forKey: PreferenceKey.lastSpeakerName) ?? ""
        lastSource = defaults.string(forKey: PreferenceKey.lastSource) ?? ""
        lastModelCode = defaults.string(forKey: PreferenceKey.lastModelCode) ?? ""
        lastIsSecure = defaults.object(forKey: PreferenceKey.lastIsSecure) as? Bool
        knownSpeakers = defaults.data(forKey: PreferenceKey.knownSpeakers)
            .flatMap { try? JSONDecoder().decode([SavedSpeaker].self, from: $0) } ?? []
    }

    /// Add or refresh a speaker in ``knownSpeakers`` (moved to the front). Writes only on change.
    public func remember(_ speaker: SavedSpeaker) {
        var speakers = knownSpeakers
        speakers.removeAll { $0.id == speaker.id }
        speakers.insert(speaker, at: 0)
        if speakers.count > 10 { speakers.removeLast(speakers.count - 10) }
        if speakers != knownSpeakers { knownSpeakers = speakers }
    }
}
