import SwiftUI

/// The app icon's two colours: the saffron cabinet (``CabinetArt``, AccentColor) sits on this
/// deep teal ink. Values match scripts/make-ios-icon.swift (bgTop, bgBottom, bgGlow).
enum BrandTeal {
    static let top = Color(red: 0x18 / 255, green: 0x50 / 255, blue: 0x5C / 255)
    static let bottom = Color(red: 0x07 / 255, green: 0x20 / 255, blue: 0x29 / 255)
    static let glow = Color(red: 0x2F / 255, green: 0x7E / 255, blue: 0x8C / 255)
}

/// The cabinet on a teal rounded square, like the app icon: the hero's "artwork" when the
/// speaker has none, and the onboarding and offline pictures. Asleep (standby, unreachable)
/// turns the whole tile slate grey and dims the cabinet.
struct CabinetTile: View {
    var isAsleep = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .background {
                ZStack {
                    LinearGradient(colors: [BrandTeal.top, BrandTeal.bottom], startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [BrandTeal.glow.opacity(0.55), .clear],
                                   center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 260)
                        .scaleEffect(1.2)
                }
                .saturation(isAsleep ? 0.25 : 1)
                .brightness(isAsleep ? -0.04 : 0)
                .clipShape(CabinetTileShape())
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            }
            .overlay {
                CabinetArt(isAsleep: isAsleep)
                    .padding(.top, 2)
                    .scaleEffect(0.72)
            }
            .animation(.easeInOut(duration: 0.35), value: isAsleep)
    }
}

/// Same rounded square as album artwork: corners shrink with the tile so a small one stays a
/// rounded square.
struct CabinetTileShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(28, rect.width * 0.12), style: .continuous)
    }
}
