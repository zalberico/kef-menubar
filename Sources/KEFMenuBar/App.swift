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
            #if !APPSTORE
                .environment(appDelegate.updater)
            #endif
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
            #if !APPSTORE
                .environment(appDelegate.updater)
            #endif
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = Self.makeModel()
    private var preferences: Preferences { model.preferences }
    #if !APPSTORE
    /// Sparkle starts with the app, so scheduled checks (once allowed) run from launch.
    /// The Mac App Store build (APPSTORE) has no Sparkle: the App Store updates it.
    let updater = AppUpdater()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !APPSTORE
        // A copy just downloaded and opened from Downloads offers to move itself first.
        if MoveToApplications.offerIfNeeded() { return }
        #endif
        model.start()
        HotKeyCenter.shared.install()
        HotKeyCenter.shared.handler = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.registerAll = { [preferences] in Self.registerHotKeys(preferences) }
        Self.registerHotKeys(preferences)
        #if DEBUG
        #if APPSTORE
        let panel = AnyView(PopoverView().environment(model))
        #else
        let panel = AnyView(PopoverView().environment(model).environment(updater))
        #endif
        DemoScenes.start(model: model, panel: panel)
        #endif
    }

    private static func makeModel() -> SpeakerModel {
        #if DEBUG
        // Debug builds only: `-DemoSpeaker` shows a made-up speaker for screenshots, with
        // nothing on the network (see DemoSpeaker in KEFAppCore).
        if DemoSpeaker.isEnabled { return DemoSpeaker.makeModel(logSubsystem: "KEFMenuBar") }
        #endif
        return SpeakerModel(preferences: Preferences())
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
            .accessibilityLabel("Speakeasy")
            .accessibilityValue(model.statusText)
    }

    static func style(for model: SpeakerModel) -> SpeakerGlyph.Style {
        switch model.connection {
        case .offline: .offline
        case .online where model.isOn: model.muted ? .muted : .on
        default: .standby
        }
    }
}

/// The app's version as Settings shows it: "1.2.0 (42)".
enum AppVersion {
    static var current: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
