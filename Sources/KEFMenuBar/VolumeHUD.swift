import AppKit
import Observation
import SwiftUI

/// A small, non-activating volume overlay shown when a hot key changes the volume.
@MainActor
final class VolumeHUD {
    static let shared = VolumeHUD()

    @Observable final class State {
        var title = ""
        var volume = 0
        var ceiling = 100
        var muted = false
        var offline = false
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show(title: String, volume: Int, ceiling: Int, muted: Bool, offline: Bool) {
        state.title = title
        state.volume = volume
        state.ceiling = ceiling
        state.muted = muted
        state.offline = offline
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(1300))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(state: state))
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        return panel
    }

    /// Top-right of the screen with the pointer, under the menu bar (where macOS shows its own).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 10))
    }
}

private struct HUDView: View {
    let state: VolumeHUD.State

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: SpeakerGlyph.image(glyph, height: 24))
                .renderingMode(.template)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.offline ? "\(state.title) — offline" : state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LevelBar(fraction: state.muted || state.offline ? 0 : Double(state.volume) / 100,
                         limit: state.ceiling < 100 ? Double(state.ceiling) / 100 : nil)
            }
            Text(state.muted ? "—" : "\(state.volume)")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(width: 260, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }

    private var glyph: SpeakerGlyph.Style {
        if state.offline { return .offline }
        return state.muted ? .muted : .on
    }
}

private struct LevelBar: View {
    let fraction: Double
    let limit: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.primary).frame(width: max(0, geometry.size.width * fraction))
                if let limit {
                    Rectangle().fill(.orange).frame(width: 2).offset(x: geometry.size.width * limit - 1)
                }
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.12), value: fraction)
    }
}
