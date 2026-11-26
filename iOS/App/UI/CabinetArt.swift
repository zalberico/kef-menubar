import SwiftUI

/// The full-colour speaker cabinet (the app icon's saffron cabinet, without its teal ground,
/// drawn by scripts/make-ios-icon.swift), for large places: the hero with no artwork,
/// onboarding, the offline screen and the speaker list. Small tinted places keep the
/// monochrome ``SpeakerGlyph``.
struct CabinetArt: View {
    /// Standby and unreachable: desaturated and faded, so it reads as asleep.
    var isAsleep = false
    /// Spoken name, when no text next to it already says what it shows; otherwise decorative.
    var label: String?

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .saturation(isAsleep ? 0.2 : 1)
            .opacity(isAsleep ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.35), value: isAsleep)
    }

    private var image: Image {
        if let label {
            Image("SpeakerCabinet", label: Text(label))
        } else {
            Image(decorative: "SpeakerCabinet")
        }
    }
}

/// Width over height of ``CabinetArt``'s image (160 × 200 pt, room for its shadow below).
extension CabinetArt {
    static let aspectRatio: CGFloat = 0.8
}
