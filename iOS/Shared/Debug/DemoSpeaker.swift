#if DEBUG
import Foundation
import KEFAppCore
import KEFKit

/// The iPhone app's part of the demo speaker (the speaker itself, `-DemoSpeaker`, is in
/// KEFAppCore, which the Mac app shares).
///
/// `-DemoIntents YES` (with `-DemoSpeaker`) also points the intents, controls and widgets
/// at a demo speaker until the app is next launched without it: the app sets a flag in the
/// App Group, and each process then serves its own fake whose state is kept in the App
/// Group (`demo-speaker.json`), so a change made from Control Center is still there for the
/// widget. They write the widgets' snapshot, which the real app rewrites once it runs again.
extension DemoSpeaker {
    private static let intentsFlag = "DebugDemoIntents"

    /// The app was launched with `-DemoSpeaker -DemoIntents YES` last time.
    static var intentsUseDemo: Bool { AppGroup.defaults().bool(forKey: intentsFlag) }

    /// Called by the app at launch: turns the demo on for the extension, or off.
    static func setIntentsUseDemo(_ enabled: Bool) {
        if enabled {
            AppGroup.defaults().set(true, forKey: intentsFlag)
            // The extension starts from the app's demo (its launch arguments: volume limit,
            // input), not from a stale run.
            saveIntentState()
        } else {
            AppGroup.defaults().removeObject(forKey: intentsFlag)
            if let url = stateURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The configuration the intents use for the demo speaker.
    static var intentConfig: SharedSpeakerConfig {
        SharedSpeakerConfig(hostMode: .manual, manualHost: host, lastSpeakerName: name,
                            lastSource: Source.wifi.rawValue, lastModelCode: modelCode)
    }

    private static var stateURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("demo-speaker.json")
    }

    /// Load the state the last intent left, before using the fake.
    static func loadIntentState() {
        guard let url = stateURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(DemoSpeakerState.Saved.self, from: data) else { return }
        DemoSpeakerState.shared.restore(saved)
    }

    /// Keep the fake's state for the next intent, control or widget.
    static func saveIntentState() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(DemoSpeakerState.shared.saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
