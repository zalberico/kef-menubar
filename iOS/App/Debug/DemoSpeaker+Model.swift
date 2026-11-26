#if DEBUG
import Foundation
import KEFAppCore
import KEFKit

extension DemoSpeaker {
    /// `-DemoIntents YES`: the intents, controls and widgets use a demo speaker too.
    static var intentsArgument: Bool { UserDefaults.standard.bool(forKey: "DemoIntents") }

    @MainActor static func makeModel() -> SpeakerModel {
        makeModel(logSubsystem: AppLog.subsystem)
    }
}
#endif
