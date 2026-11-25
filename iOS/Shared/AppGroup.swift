import Foundation
import KEFAppCore

/// The App Group the app and its extension share: preferences, the widget snapshot and
/// (in debug builds) the probe log. Its identifier comes from the `AppGroupIdentifier`
/// Info.plist key, which the build sets from `APP_GROUP_ID` in Base.xcconfig, so renaming
/// the group never touches code.
enum AppGroup {
    static let identifier: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !value.isEmpty, !value.hasPrefix("$(") else {
            preconditionFailure("AppGroupIdentifier is missing from Info.plist")
        }
        return value
    }()

    /// The shared preferences suite (falls back to the standard defaults if the group is
    /// unavailable, which only happens with broken signing).
    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// The shared container, `nil` if the App Group entitlement is missing.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where the widgets' snapshot and artwork live.
    static var snapshotStore: SnapshotStore? {
        containerURL.map { SnapshotStore(containerURL: $0.appendingPathComponent("Widgets", isDirectory: true)) }
    }

    /// The speaker configuration the app saved, read fresh.
    static func speakerConfig() -> SharedSpeakerConfig {
        SharedSpeakerConfig.load(suiteName: identifier)
    }
}
