import SwiftUI

// The building blocks the Sound and Settings panels share: inset grouped cards in a scroll
// view that keeps its place when the panel moves between the sheet and the side column.

/// A panel's scroll view of cards. A `Form` ignores `ScrollPosition`, and the sheet and the
/// wide layout's column are different views, so how far it is scrolled is kept in
/// ``UIState`` and scrolled back to when the panel moves between them.
struct PanelScrollView<Content: View>: View {
    @Binding var position: ScrollPosition
    /// Where the person left it (`ScrollPosition` doesn't record a scroll by hand).
    @Binding var offset: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .onScrollPhaseChange { oldPhase, phase, context in
            // Only where the person left it: a view appearing or going away reports 0.
            guard oldPhase != .idle, phase == .idle else { return }
            offset = max(0, context.geometry.contentOffset.y + context.geometry.contentInsets.top)
        }
        .onAppear {
            // A new panel (sheet <-> column) starts where the other one was.
            if offset > 1 { position.scrollTo(y: offset) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// An inset grouped card, like a form section: an optional header and footer, and a
/// separator between rows.
struct CardSection<Content: View>: View {
    var header: LocalizedStringKey?
    /// A note under the card (often built from the speaker's state, so not a key).
    var footer: String?
    @ViewBuilder var content: Content

    init(header: LocalizedStringKey? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        if row.id != rows.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: .rect(cornerRadius: 24, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 20)
    }
}

/// A title and its control on one line; the control under the title at accessibility sizes.
struct LabeledRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            Text(title)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            control
        }
        .accessibilityElement(children: .combine)
    }
}


/// A short choice: segmented, under its title; a menu at accessibility sizes, where three
/// segments can't fit their words.
struct ChoiceRow<Tag: Hashable & Sendable>: View {
    let title: String
    let selection: Tag
    let options: [EQChoice<Tag>]
    /// Off where the section header already names the choice.
    var showsTitle = true
    let choose: (Tag) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var changes = 0

    var body: some View {
        let picker = Picker(title, selection: Binding(get: { selection }, set: { tag in
            guard tag != selection else { return }
            changes += 1
            choose(tag)
        })) {
            ForEach(options) { option in
                Text(option.label).tag(option.tag)
            }
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    if showsTitle {
                        Text(title)
                            .accessibilityHidden(true)  // the menu's own label
                    }
                    MenuPicker(title: title, valueLabel: options.first { $0.tag == selection }?.label ?? "") {
                        picker
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if showsTitle {
                        Text(title)
                            .accessibilityHidden(true)  // the picker's own label
                    }
                    picker
                        .pickerStyle(.segmented)
                        .labelsHidden()
                }
            }
        }
        .sensoryFeedback(.selection, trigger: changes)
    }
}

/// A picker shown as a menu whose label is just the current value and a chevron, with no
/// button insets, so the value lines up with the other rows' edges (a menu-style `Picker`
/// brings its own padding, which a `Form` would absorb and these cards don't).
struct MenuPicker<Content: View>: View {
    let title: String
    let valueLabel: String
    @ViewBuilder var picker: Content

    var body: some View {
        Menu {
            picker
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(valueLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(valueLabel)
    }
}
