import KEFAppCore
import KEFKit
import SwiftUI

/// A glass tile for each input this speaker has: one row when they fit, else wrapped into
/// even rows (compact), or one scrolling row (landscape, where height is short).
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
                // One row, scrolling when it doesn't fit. The glass container sits inside
                // the scroll view so the scroll view clips the tiles.
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            chips(inputs, current: current, width: 78)
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .sensoryFeedback(.selection, trigger: selections)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inputs")
    }

    private func chips(_ inputs: [Source], current: Source?, width: CGFloat? = nil) -> some View {
        ForEach(inputs, id: \.self) { source in
            InputChip(source: source, isSelected: source == current, width: width) {
                guard source != current else { return }
                selections += 1
                model.select(source)
            }
        }
    }
}

private struct InputChip: View {
    let source: Source
    let isSelected: Bool
    /// A fixed width (the scrolling row), else as wide as the layout makes it.
    let width: CGFloat?
    let action: () -> Void

    var body: some View {
        let button = Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: source.symbol)
                    .font(.title3)
                    .frame(height: 24)
                Text(source.shortName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minWidth: width ?? 64, maxWidth: width ?? .infinity, minHeight: 44)
        }
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .accessibilityLabel(source.displayName)
        .accessibilityHint(isSelected ? "" : "Switches the speaker to this input")
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}
