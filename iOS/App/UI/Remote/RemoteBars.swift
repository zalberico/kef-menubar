import KEFAppCore
import KEFKit
import SwiftUI

/// Sound and Settings at the bottom. In the wide layout they switch the side column, and
/// the one shown is highlighted.
struct PanelBar: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui
    @Environment(\.isWideLayout) private var isWide
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let selected: UIState.Panel? = isWide ? ui.columnPanel : nil
        let iconOnly = dynamicTypeSize.isAccessibilitySize
        // Both titles, or (a narrow remote column) both symbols alone.
        ViewThatFits(in: .horizontal) {
            buttons(selected: selected, iconOnly: iconOnly)
            buttons(selected: selected, iconOnly: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func buttons(selected: UIState.Panel?, iconOnly: Bool) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PanelButton(title: "Sound", symbol: "slider.horizontal.3", isSelected: selected == .sound,
                            showsBadge: false, iconOnly: iconOnly) {
                    ui.open(.sound, isWide: isWide)
                }
                PanelButton(title: "Settings", symbol: "gearshape", isSelected: selected == .settings,
                            showsBadge: model.firmwareUpdateAvailable, iconOnly: iconOnly) {
                    ui.open(.settings, isWide: isWide)
                }
            }
        }
    }
}

private struct PanelButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    /// A dot for news (a firmware update).
    let showsBadge: Bool
    /// Accessibility text sizes, or titles that don't fit: the symbol only (the large
    /// content viewer shows the title).
    let iconOnly: Bool
    let action: () -> Void

    var body: some View {
        let button = Button {
            action()
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(iconOnly ? AnyLabelStyle.iconOnly : .titleAndIcon)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 30)
                .overlay(alignment: .topTrailing) {
                    if showsBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                            .offset(x: -6, y: -2)
                    }
                }
        }
        .controlSize(.large)
        .accessibilityLabel(title)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: symbol)
        }
        .accessibilityValue(showsBadge ? "Firmware update available" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if isSelected {
            button.prominentGlassStyle()
        } else {
            button.buttonStyle(.glass)
        }
    }
}

/// Transient notices over the top of the remote: a firmware update in progress, and the
/// last error (the model clears it after a few seconds).
struct BannerStack: View {
    @Environment(SpeakerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if model.showsFirmwareUpdating {
                Banner {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                    Text(firmwareText)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = model.lastError {
                Banner(tint: .red) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .lineLimit(3)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear { AccessibilityNotification.Announcement(error).post() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .animation(.spring(duration: 0.35), value: model.lastError)
        .animation(.spring(duration: 0.35), value: model.showsFirmwareUpdating)
    }

    private var firmwareText: String {
        if let progress = model.firmwareProgress { return "Updating firmware… \(progress)%" }
        return model.isOnline ? "Updating firmware…" : "Restarting after update…"
    }
}

private struct Banner<Content: View>: View {
    var tint: Color?
    let content: Content

    init(tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(tint?.opacity(0.18)), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

/// Lets a ternary pick between label styles.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView

    static let iconOnly = AnyLabelStyle { AnyView(IconOnlyLabelStyle().makeBody(configuration: $0)) }
    static let titleAndIcon = AnyLabelStyle { AnyView(TitleAndIconLabelStyle().makeBody(configuration: $0)) }

    private init(_ make: @escaping (Configuration) -> AnyView) { self.make = make }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
