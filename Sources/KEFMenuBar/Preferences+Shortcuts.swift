import Foundation
import KEFAppCore

/// The keyboard shortcuts, stored next to the shared preferences (Mac only).
extension Preferences {
    func shortcut(for action: HotKeyAction) -> KeyCombo? {
        guard let data = defaults.data(forKey: "shortcut.\(action.rawValue)") else { return action.defaultCombo }
        return try? JSONDecoder().decode(KeyCombo?.self, from: data)
    }

    func setShortcut(_ combo: KeyCombo?, for action: HotKeyAction) {
        defaults.set(try? JSONEncoder().encode(combo), forKey: "shortcut.\(action.rawValue)")
    }
}
