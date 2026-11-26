import KEFAppCore
import KEFKit
import SwiftUI

/// A glass tile for each input this speaker has: one row when they fit, else wrapped into
/// even rows (compact), or one scrolling row (landscape, where height is short) sized so
/// the next tile peeks in when they don't all fit.
struct InputChips: View {
    let allowsWrapping: Bool

    @Environment(SpeakerModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The selected tile's glass moves between tiles in this namespace.
    @Namespace private var highlight

    var body: some View {
        let inputs = model.pickerInputs
        let current = model.displaysOn ? model.source : nil
        Group {
            if allowsWrapping {
                GlassEffectContainer(spacing: 8) {
                    EvenGridLayout(spacing: 8) { chips(inputs, current: current) }
                }
            } else {
                // One row, scrolling when it doesn't fit: four and a half tiles show, so
                // the half tile (and the indicator flashed on appear) says there's more.
                // Four or fewer share the width. The glass container sits inside the
                // scroll view so the scroll view clips the tiles.
                let count = min(9, max(1, inputs.count) * 2)
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            chips(inputs, current: current, columns: count)
                        }
                        .padding(.bottom, 6)  // room for the scroll indicator
                    }
                }
                .scrollIndicatorsFlash(onAppear: true)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        // The highlight slides to the new tile (it just moves with Reduce Motion).
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inputs")
    }

    /// `columns`: in the scrolling row, each tile spans two of this many columns of the
    /// scroll view's width.
    private func chips(_ inputs: [Source], current: Source?, columns: Int? = nil) -> some View {
        ForEach(inputs, id: \.self) { source in
            InputChip(source: source, isSelected: source == current, highlight: highlight) {
                guard source != current else { return }
                model.select(source)
            }
            .modifier(ScrollRowWidth(columns: columns))
        }
    }
}

private struct ScrollRowWidth: ViewModifier {
    let columns: Int?

    func body(content: Content) -> some View {
        if let columns {
            content.containerRelativeFrame(.horizontal, count: columns, span: 2, spacing: 8)
        } else {
            content
        }
    }
}

/// A glass tile; the selected one is amber glass that moves between tiles (one glass with
/// an identity in the tiles' container, which morphs it) rather than a style each turns on.
private struct InputChip: View {
    let source: Source
    let isSelected: Bool
    let highlight: Namespace.ID
    let action: () -> Void

    /// The symbol's box grows with the text, so large sizes never overlap the name.
    @ScaledMetric(relativeTo: .title3) private var iconHeight: CGFloat = 24

    var body: some View {
        let button = Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: source.symbol)
                    .font(.title3)
                    .frame(height: iconHeight)
                Text(source.shortName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: 64, maxWidth: .infinity, minHeight: 44)
        }
        .buttonBorderShape(.roundedRectangle(radius: 16))

        Group {
            if isSelected {
                // One tinted glass, identified across tiles: the container morphs it from
                // the old tile to the new one.
                button.buttonStyle(SelectedChipStyle(highlight: highlight))
            } else {
                button.buttonStyle(.glass)
            }
        }
        .accessibilityLabel(source.displayName)
        .accessibilityHint(isSelected ? "" : "Switches the speaker to this input")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The selected tile's label over the highlight: the prominent label colour, dimmed while
/// pressed (it is already selected, so a press does nothing).
private struct SelectedChipStyle: ButtonStyle {
    let highlight: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(Color.prominentLabel)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 16))
            .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 16, style: .continuous))
            .glassEffectID("selected", in: highlight)
    }
}
