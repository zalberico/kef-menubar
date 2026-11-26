#if DEBUG
import AppKit
import KEFAppCore
import SwiftUI

/// Debug only, with `-DemoSpeaker`: opens parts of the app at launch for screenshots, with
/// no clicking. `-DemoShowPopover YES` opens the menu bar panel, `-DemoShowSettings YES` the
/// Settings window (`-settingsTab speaker` picks its tab), and `-DemoShowHUD YES` keeps the
/// volume overlay up, as a volume hot key shows it. `-DemoAppearance light` (or `dark`)
/// overrides the system appearance.
///
/// `-DemoSnapshot <folder>` saves PNGs of the panel, the Settings window and the overlay
/// there, drawn in process (window capture needs the Screen Recording permission). Vibrancy
/// and Liquid Glass don't survive that, so the panel is drawn in a plain, transparent window
/// (`Popover.png`, its content only); the material behind it is the screenshot's to add.
@MainActor
enum DemoScenes {
    static func start(model: SpeakerModel, panel: AnyView) {
        guard DemoSpeaker.isEnabled else { return }
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "DemoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        Task {
            try? await Task.sleep(for: .seconds(1.5))  // the demo speaker connects first
            if defaults.bool(forKey: "DemoShowPopover") { openPopover() }
            if defaults.bool(forKey: "DemoShowSettings") { openSettings() }
            if defaults.bool(forKey: "DemoShowHUD") { showHUD(model: model) }
            if let path = defaults.string(forKey: "DemoSnapshot") {
                let folder = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let popover = hostOffscreen(panel, width: 330)
                try? await Task.sleep(for: .seconds(2))
                snapshot(popover, to: folder.appendingPathComponent("Popover.png"))
                popover.window?.close()
                for window in NSApp.windows where window.isVisible {
                    if window is NSPanel {
                        snapshot(window.contentView, to: folder.appendingPathComponent("HUD.png"))
                    } else if window.styleMask.contains(.titled) {
                        window.alphaValue = 0
                        forceActiveControls(window)
                        try? await Task.sleep(for: .seconds(0.5))
                        snapshot(window.contentView?.superview, to: folder.appendingPathComponent("Settings.png"))
                    }
                }
                NSLog("DemoSnapshot: wrote %@", folder.path)
            }
        }
    }

    /// Opens the menu bar panel as a click on the status item does.
    private static func openPopover() {
        for window in NSApp.windows {
            guard let item = window.value(forKey: "statusItem") as? NSStatusItem else { continue }
            // macOS 26 and later host status items out of process; this asks for the panel.
            let request = Selector(("_requestExpandedInterfaceSession"))
            if item.responds(to: request) {
                _ = item.perform(request)
            } else {
                item.button?.performClick(nil)
            }
            return
        }
    }

    /// Settings…, from the app menu SwiftUI builds.
    private static func openSettings() {
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            if let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: index)
                return
            }
        }
    }

    /// Shows the volume overlay again every second, so it never fades.
    private static func showHUD(model: SpeakerModel) {
        Task {
            while true {
                VolumeHUD.shared.show(title: model.name, volume: model.volume, ceiling: model.volumeCeiling,
                                      muted: model.muted, offline: !model.isOnline)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A view in an invisible window on the main screen (so it draws at the screen's scale).
    private static func hostOffscreen(_ view: some View, width: CGFloat) -> NSView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        forceActiveControls(window)
        window.orderFrontRegardless()
        return host
    }

    /// Makes a window draw as the frontmost app's key window (colored window buttons, blue
    /// switches), though this app stays in the background: a subclass made at run time
    /// answers yes to "are you key?".
    private static func forceActiveControls(_ window: NSWindow) {
        let base: AnyClass = type(of: window)
        let name = "DemoKey_" + NSStringFromClass(base)
        var subclass: AnyClass? = NSClassFromString(name)
        if subclass == nil, let made = objc_allocateClassPair(base, name, 0) {
            let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
            for selector in ["isKeyWindow", "isMainWindow", "_hasActiveControls", "_hasKeyAppearance", "hasKeyAppearance"] {
                let sel = Selector(selector)
                if let method = class_getInstanceMethod(base, sel) {
                    class_addMethod(made, sel, imp_implementationWithBlock(yes), method_getTypeEncoding(method))
                }
            }
            objc_registerClassPair(made)
            subclass = made
        }
        guard let subclass else { return }
        object_setClass(window, subclass)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        func redraw(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(redraw) }
        window.contentView?.superview.map(redraw)
    }

    /// Draws a view's layer tree into a PNG at the window's scale.
    private static func snapshot(_ view: NSView?, to url: URL) {
        guard let view, let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }
}

#endif
