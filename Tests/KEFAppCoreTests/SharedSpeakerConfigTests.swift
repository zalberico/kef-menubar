import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

struct SharedSpeakerConfigTests {
    /// A throwaway suite, removed afterwards.
    func withSuite(_ body: (String, UserDefaults) throws -> Void) rethrows {
        let name = "KEFAppCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(name, defaults)
    }

    @Test func readsWhatThePreferencesWrote() {
        withSuite { name, defaults in
            let host = ["192", "0", "2", "7"].joined(separator: ".")
            defaults.set("manual", forKey: PreferenceKey.hostMode)
            defaults.set(" \(host) ", forKey: PreferenceKey.manualHost)
            defaults.set("Kitchen", forKey: PreferenceKey.lastSpeakerName)
            defaults.set("tv", forKey: PreferenceKey.lastSource)
            defaults.set("SP4025", forKey: PreferenceKey.lastModelCode)
            defaults.set(true, forKey: PreferenceKey.lastIsSecure)
            defaults.set(5, forKey: PreferenceKey.volumeStep)
            let config = SharedSpeakerConfig.load(suiteName: name)
            #expect(config.hostMode == .manual)
            #expect(config.host == host)
            #expect(config.lastSpeakerName == "Kitchen")
            #expect(config.lastInput == .tv)
            #expect(config.modelCode == "SP4025")
            #expect(config.lastIsSecure == true)
            #expect(config.volumeStep == 5)
        }
    }

    @Test func emptySuiteHasDefaultsAndNoHost() {
        withSuite { name, _ in
            let config = SharedSpeakerConfig.load(suiteName: name)
            #expect(config.hostMode == .automatic)
            #expect(config.host == nil)
            #expect(config.lastIsSecure == nil)
            #expect(config.lastInput == nil)
            #expect(config.modelCode == nil)
            #expect(config.volumeStep == PreferenceKey.defaultVolumeStep)
            #expect(config.volumeStep == 2)
        }
    }

    /// Out-of-range steps read as the default, exactly like `Preferences`, so the widgets
    /// and the app always agree.
    @Test(arguments: [0, -3, 11, 99])
    func outOfRangeStepReadsAsTheDefault(stored: Int) {
        withSuite { name, defaults in
            defaults.set(stored, forKey: PreferenceKey.volumeStep)
            #expect(SharedSpeakerConfig.load(suiteName: name).volumeStep == 2)
        }
    }

    @Test(arguments: [1, 10])
    func inRangeStepIsKept(stored: Int) {
        withSuite { name, defaults in
            defaults.set(stored, forKey: PreferenceKey.volumeStep)
            #expect(SharedSpeakerConfig.load(suiteName: name).volumeStep == stored)
        }
    }

    @MainActor @Test func agreesWithPreferences() {
        withSuite { name, defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.volumeStep = 7
            preferences.lastHost = ["192", "0", "2", "8"].joined(separator: ".")
            preferences.lastModelCode = "SP4077"
            preferences.lastIsSecure = false
            preferences.remember(SavedSpeaker(id: "a", name: "One", host: "h1"))
            preferences.remember(SavedSpeaker(id: "b", name: "Two", host: "h2"))
            preferences.remember(SavedSpeaker(id: "a", name: "One again", host: "h3"))
            let config = SharedSpeakerConfig.load(suiteName: name)
            #expect(config.volumeStep == 7)
            #expect(config.host == preferences.lastHost)
            #expect(config.modelCode == "SP4077")
            #expect(config.lastIsSecure == false)
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.knownSpeakers.map(\.id) == ["a", "b"])
            #expect(reloaded.knownSpeakers.first?.host == "h3")
            #expect(reloaded.volumeStep == 7)
        }
    }
}
