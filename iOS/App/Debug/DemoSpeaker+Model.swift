#if DEBUG
import Foundation
import KEFAppCore
import KEFKit

extension DemoSpeaker {
    /// `-DemoIntents YES`: the intents, controls and widgets use a demo speaker too.
    static var intentsArgument: Bool { UserDefaults.standard.bool(forKey: "DemoIntents") }

    @MainActor static func makeModel() -> SpeakerModel {
        let suite = "\(AppLog.subsystem).demo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        preferences.lastHost = host
        preferences.lastSpeakerName = name
        preferences.lastSource = Source.wifi.rawValue
        return SpeakerModel(
            preferences: preferences,
            logSubsystem: AppLog.subsystem,
            makeClient: { host in makeClient(host: host) },
            discover: { [] })
    }
}
#endif
