import KEFAppCore
import KEFKit
import SwiftUI

/// The remote: now playing, volume and inputs. One column in the compact layouts (the
/// artwork gives up space first, so volume and inputs always stay on screen), side by side
/// in landscape. At accessibility text sizes the whole thing scrolls.
struct RemoteContent: View {
    let layout: RemoteLayout
    /// Cached values while reconnecting: shown dimmed, nothing can be changed.
    let readOnly: Bool

    @Environment(UIState.self) private var ui
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            @Bindable var ui = ui
            ScrollView {
                RemoteStack(layout: layout, scrolls: true)
            }
            .scrollPosition($ui.remoteScroll)
            .scrollBounceBehavior(.basedOnSize)
            .modifier(ReadOnly(isOn: readOnly))
        } else {
            RemoteStack(layout: layout, scrolls: false)
                .modifier(ReadOnly(isOn: readOnly))
        }
    }
}

private struct ReadOnly: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isOn)
            .opacity(isOn ? 0.5 : 1)
            .saturation(isOn ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.3), value: isOn)
    }
}

private struct RemoteStack: View {
    let layout: RemoteLayout
    let scrolls: Bool

    var body: some View {
        let isLandscape = layout == .landscape
        let stack = isLandscape
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 28))
            : AnyLayout(VStackLayout(spacing: 18))
        stack {
            NowPlayingHero(scrolls: scrolls)
            VStack(spacing: 16) {
                VolumeControl()
                InputChips(allowsWrapping: !isLandscape || scrolls)
            }
            .frame(maxWidth: isLandscape ? 440 : 560)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}
