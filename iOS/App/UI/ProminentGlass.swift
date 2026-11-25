import SwiftUI

extension View {
    /// `.glassProminent` with a label colour that stays readable on the amber fill: white on
    /// the deep light-mode amber, near-black on the bright dark-mode one (both at least
    /// 4.5:1, and stronger with Increase Contrast; see the ProminentLabel colour).
    func prominentGlassStyle() -> some View {
        buttonStyle(.glassProminent)
            .foregroundStyle(Color.prominentLabel)
    }
}
