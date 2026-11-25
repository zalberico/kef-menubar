import KEFAppCore
import KEFKit
import SwiftUI

/// A glass tile for each input this speaker has: one row when they fit, else wrapped into
/// even rows (compact), or one scrolling row (landscape, where height is short) sized so
/// the next tile peeks in when they don't all fit.
struct InputChips: View {
    let allowsWrapping: Bool

    @Environment(SpeakerModel.self) private var model
    @State private var selections = 0

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
        .sensoryFeedback(.selection, trigger: selections)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inputs")
    }

    /// `columns`: in the scrolling row, each tile spans two of this many columns of the
    /// scroll view's width.
    private func chips(_ inputs: [Source], current: Source?, columns: Int? = nil) -> some View {
        ForEach(inputs, id: \.self) { source in
            InputChip(source: source, isSelected: source == current) {
                guard source != current else { return }
                selections += 1
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

private struct InputChip: View {
    let source: Source
    let isSelected: Bool
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
        .accessibilityLabel(source.displayName)
        .accessibilityHint(isSelected ? "" : "Switches the speaker to this input")
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            button.prominentGlassStyle()
        } else {
            button.buttonStyle(.glass)
        }
    }
}
