import KEFAppCore
import KEFKit
import SwiftUI

/// The volume, like the Mac app's: a slider clamped to the speaker's own limit (with a tick
/// where it is, when it is on), − and + by the app's volume step, and mute.
struct VolumeControl: View {
    @Environment(SpeakerModel.self) private var model

    @State private var ups = 0
    @State private var downs = 0
    @State private var limitHits = 0
    /// The slider is being dragged: its ticks are for the drag, not for the speaker's changes.
    @State private var isDragging = false

    var body: some View {
        let ceiling = model.volumeCeiling
        let limit = model.volumeLimited ? ceiling : nil
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    VolumeReadout(volume: model.volume, muted: model.muted, limit: limit)
                    Spacer(minLength: 8)
                    buttons
                }
                VStack(alignment: .leading, spacing: 10) {
                    VolumeReadout(volume: model.volume, muted: model.muted, limit: limit)
                    buttons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VolumeSlider(volume: model.volume, muted: model.muted, limit: limit) { value in
                setFromSlider(value)
            } adjust: { direction in
                step(direction)
            } editingChanged: { editing in
                isDragging = editing
            }
            .modifier(LevelTicks(level: isDragging ? model.volume : nil, ceiling: ceiling))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .disabled(!model.isOn || model.inputSettling)
        .sensoryFeedback(.increase, trigger: ups)
        .sensoryFeedback(.decrease, trigger: downs)
        .sensoryFeedback(.impact(weight: .heavy), trigger: limitHits)
        // Mute's own haptic comes when the speaker confirms it (CommandHaptics).
    }

    private var buttons: some View {
        // Symbols in fixed circles: capped size, the large content viewer shows them bigger.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                StepButton(symbol: "minus", label: "Volume Down") { step(-1) }
                StepButton(symbol: "plus", label: "Volume Up") { step(1) }
                MuteButton(muted: model.muted) {
                    model.toggleMute()
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// One step of the app's volume step; + unmutes, like the Mac.
    private func step(_ direction: Int) {
        let delta = direction * model.preferences.volumeStep
        let before = model.volume
        model.stepVolume(by: delta)
        if delta > 0, before + delta > model.volumeCeiling, model.volumeLimited {
            limitHits += 1
        } else if delta > 0 {
            ups += 1
        } else {
            downs += 1
        }
    }

    private func setFromSlider(_ value: Double) {
        let requested = Int(value.rounded())
        guard requested != model.volume else { return }
        model.setVolume(requested)
    }
}

/// The big number, and what it means.
private struct VolumeReadout: View {
    let volume: Int
    let muted: Bool
    let limit: Int?

    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 54
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(volume, format: .number)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                // Digits roll with the value; with Reduce Motion they just change.
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(volume)))
                .foregroundStyle(muted ? .secondary : .primary)
                .animation(reduceMotion ? nil : .snappy, value: volume)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityHidden(true)  // the slider reads the volume out
    }

    private var caption: String {
        if muted { return "Muted" }
        if let limit { return "Volume · limit \(limit)" }
        return "Volume"
    }
}

private struct StepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: symbol)
        }
    }
}

private struct MuteButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        let button = Button {
            action()
        } label: {
            MuteSymbol(muted: muted)
                .font(.title3)
                .frame(width: 40, height: 40)
        }
        .buttonBorderShape(.circle)
        // A toggle: VoiceOver reads "Mute, switch button, on" while muted.
        .accessibilityLabel("Mute")
        .accessibilityAddTraits(muted ? [.isToggle, .isSelected] : .isToggle)

        if muted {
            button.prominentGlassStyle()
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// The speaker's mute state: the slash draws in and out (a crossfade with Reduce Motion).
/// Shared with the mute button in the vertical bar.
struct MuteSymbol: View {
    let muted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
    }
}

/// Haptics for dragging a 0…100 level: a light tick at every ten and a firmer bump on
/// reaching the speaker's limit (100 without one), never one per step. `level` is `nil`
/// while nothing is being dragged, so changes from the speaker stay silent. Shared with
/// the volume sliders in Settings.
struct LevelTicks: ViewModifier {
    let level: Int?
    let ceiling: Int

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: level) { old, new in
            guard let old, let new, old != new else { return nil }
            if new >= ceiling, old < ceiling { return .impact(weight: .heavy) }
            if new / 10 != old / 10 { return .selection }
            return nil
        }
    }
}

/// 0…100 with the part above the speaker's limit disabled and a tick at the limit.
private struct VolumeSlider: View {
    let volume: Int
    let muted: Bool
    let limit: Int?
    let set: (Double) -> Void
    let adjust: (Int) -> Void
    let editingChanged: (Bool) -> Void

    var body: some View {
        let value = Binding<Double>(get: { Double(volume) }, set: { set($0) })
        // SwiftUI's slider ticks make it snap to them, so the limit mark is drawn here.
        Slider(value: value, in: 0...100, enabledBounds: limit.map { 0...Double($0) },
               label: { Text("Volume") },
               onEditingChanged: { editing in editingChanged(editing) })
        .background {
            if let limit { LimitTick(fraction: Double(limit) / 100) }
        }
        .opacity(muted ? 0.5 : 1)
        .accessibilityLabel("Volume")
        .accessibilityValue(muted ? "\(volume), muted" : "\(volume)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }
}

/// A mark on a 0…100 slider's track at the speaker's volume limit (the thumb passes over
/// it). Shared with the startup volume sliders in Settings.
struct LimitTick: View {
    let fraction: Double

    /// The system thumb's width: its centre travels this much less than the track.
    private let thumbWidth: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.orange)
                .frame(width: 3, height: 16)
                .position(x: thumbWidth / 2 + fraction * (proxy.size.width - thumbWidth),
                          y: proxy.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}
