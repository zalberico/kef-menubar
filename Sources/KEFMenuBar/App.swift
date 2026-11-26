import AppKit
import KEFAppCore
import KEFKit
import SwiftUI

@main
struct KEFMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(appDelegate.model)
                .environment(appDelegate.updater)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.updater)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    lazy var model = SpeakerModel(preferences: preferences)
    /// Sparkle starts with the app, so scheduled checks (once allowed) run from launch.
    let updater = AppUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        HotKeyCenter.shared.install()
        HotKeyCenter.shared.handler = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.registerAll = { [preferences] in Self.registerHotKeys(preferences) }
        Self.registerHotKeys(preferences)
    }

    static func registerHotKeys(_ preferences: Preferences) {
        for action in HotKeyAction.allCases {
            HotKeyCenter.shared.register(preferences.shortcut(for: action), for: action)
        }
    }

    private func perform(_ action: HotKeyAction) {
        if model.isOnline {
            switch action {
            case .volumeUp: model.stepVolume(by: preferences.volumeStep)
            case .volumeDown: model.stepVolume(by: -preferences.volumeStep)
            case .mute: model.toggleMute()
            }
        }
        guard preferences.showHUD else { return }
        VolumeHUD.shared.show(title: model.name, volume: model.volume, ceiling: model.volumeCeiling,
                              muted: model.muted, offline: !model.isOnline)
    }
}

/// Menu bar icon: the app's own bookshelf-speaker glyph. Solid with a level meter while on,
/// slashed when muted, outlined in standby, with "!" when the speaker can't be reached.
struct MenuBarIcon: View {
    let model: SpeakerModel

    var body: some View {
        let style = Self.style(for: model)
        Image(nsImage: SpeakerGlyph.image(style, level: style == .on ? Double(model.volume) / 100 : nil))
    }

    static func style(for model: SpeakerModel) -> SpeakerGlyph.Style {
        switch model.connection {
        case .offline: .offline
        case .online where model.isOn: model.muted ? .muted : .on
        default: .standby
        }
    }
}
