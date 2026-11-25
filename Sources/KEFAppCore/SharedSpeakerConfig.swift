import Foundation
import KEFKit

/// What the widgets, controls and intents need from the app's preferences, read once into
/// a `Sendable` value (``Preferences`` itself is main-actor bound and keeps its values).
public struct SharedSpeakerConfig: Sendable, Equatable {
    public var hostMode: Preferences.HostMode
    public var manualHost: String
    /// Last address that worked in automatic mode.
    public var lastHost: String
    /// The chosen speaker's MAC address in automatic mode, `""` if none.
    public var preferredSpeakerID: String
    public var lastSpeakerName: String
    /// `Source.rawValue` of the last input used, `""` if unknown.
    public var lastSource: String
    /// Product code of the speaker last connected to, `""` if unknown.
    public var lastModelCode: String
    public var lastIsSecure: Bool?
    /// The app's volume step, always within 1...10.
    public var volumeStep: Int

    public init(
        hostMode: Preferences.HostMode = .automatic,
        manualHost: String = "",
        lastHost: String = "",
        preferredSpeakerID: String = "",
        lastSpeakerName: String = "",
        lastSource: String = "",
        lastModelCode: String = "",
        lastIsSecure: Bool? = nil,
        volumeStep: Int = PreferenceKey.defaultVolumeStep
    ) {
        self.hostMode = hostMode
        self.manualHost = manualHost
        self.lastHost = lastHost
        self.preferredSpeakerID = preferredSpeakerID
        self.lastSpeakerName = lastSpeakerName
        self.lastSource = lastSource
        self.lastModelCode = lastModelCode
        self.lastIsSecure = lastIsSecure
        self.volumeStep = PreferenceKey.volumeStep(volumeStep)
    }

    /// Read the preferences from a UserDefaults suite (an App Group on iOS), or the standard
    /// defaults for `nil`.
    public static func load(suiteName: String?) -> SharedSpeakerConfig {
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        return SharedSpeakerConfig(
            hostMode: Preferences.HostMode(rawValue: defaults.string(forKey: PreferenceKey.hostMode) ?? "") ?? .automatic,
            manualHost: defaults.string(forKey: PreferenceKey.manualHost) ?? "",
            lastHost: defaults.string(forKey: PreferenceKey.lastHost) ?? "",
            preferredSpeakerID: defaults.string(forKey: PreferenceKey.preferredSpeakerID) ?? "",
            lastSpeakerName: defaults.string(forKey: PreferenceKey.lastSpeakerName) ?? "",
            lastSource: defaults.string(forKey: PreferenceKey.lastSource) ?? "",
            lastModelCode: defaults.string(forKey: PreferenceKey.lastModelCode) ?? "",
            lastIsSecure: defaults.object(forKey: PreferenceKey.lastIsSecure) as? Bool,
            volumeStep: defaults.integer(forKey: PreferenceKey.volumeStep))
    }

    /// The address to use: the manual one, or the last one found automatically. `nil` when
    /// the app hasn't found a speaker yet.
    public var host: String? {
        let host = switch hostMode {
        case .manual: manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        case .automatic: lastHost
        }
        return host.isEmpty ? nil : host
    }

    /// The last input used, if it is a real one.
    public var lastInput: Source? {
        Source(rawValue: lastSource).flatMap { $0 == .standby ? nil : $0 }
    }

    /// The known product code, `nil` when it has to be read from the speaker.
    public var modelCode: String? { lastModelCode.isEmpty ? nil : lastModelCode }
}
