import SwiftUI

/// The app's speaker glyph (the Mac menu bar's bookshelf cabinet with a Uni-Q driver) as a
/// tintable SwiftUI shape, for the app and the widgets. Same 13 × 18 grid as the Mac's
/// `SpeakerGlyph`, with y flipped; fill it with `FillStyle(eoFill: true)` so the driver
/// rings are cut out of the cabinet.
struct SpeakerGlyphShape: Shape {
    enum Style: Sendable {
        /// Solid cabinet, driver cut out: the speaker is on.
        case on
        /// Outline with the driver drawn in: standby.
        case standby
        /// Outline with an exclamation mark: can't be reached.
        case offline
    }

    var style: Style

    /// Width over height of the glyph.
    static let aspectRatio: CGFloat = 13.0 / 18.0

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 13, rect.height / 18)
        let origin = CGPoint(x: rect.midX - 6.5 * scale, y: rect.midY - 9 * scale)
        // Grid units (y up, like the Mac drawing) to points.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + (18 - y) * scale)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            let top = point(x, y + height)
            return CGRect(x: top.x, y: top.y, width: width * scale, height: height * scale)
        }
        func circle(_ radius: CGFloat) -> Path {
            Path(ellipseIn: box(6.5 - radius, 7.6 - radius, 2 * radius, 2 * radius))
        }
        func cabinet(inset: CGFloat) -> Path {
            Path(roundedRect: box(1 + inset, 1 + inset, 11 - 2 * inset, 16 - 2 * inset),
                 cornerRadius: (2.8 - inset) * scale, style: .continuous)
        }

        var path = Path()
        switch style {
        case .on:
            path.addPath(cabinet(inset: 0))
            for radius in [4.15, 3.05, 1.75, 1.05] as [CGFloat] { path.addPath(circle(radius)) }
            path.addPath(Path(roundedRect: box(5.2, 13.6, 2.6, 1.1), cornerRadius: 0.55 * scale))
        case .standby:
            path.addPath(cabinet(inset: 0.65).strokedPath(StrokeStyle(lineWidth: 1.3 * scale)))
            path.addPath(circle(3.6).strokedPath(StrokeStyle(lineWidth: 1.2 * scale)))
            path.addPath(circle(1.0))
        case .offline:
            path.addPath(cabinet(inset: 0.65).strokedPath(StrokeStyle(lineWidth: 1.3 * scale)))
            path.addPath(Path(roundedRect: box(5.75, 6.6, 1.5, 6.6), cornerRadius: 0.75 * scale))
            path.addPath(Path(ellipseIn: box(5.65, 3.4, 1.7, 1.7)))
        }
        return path
    }
}

/// The glyph filled with the current foreground style, sized by its height.
struct SpeakerGlyph: View {
    var style: SpeakerGlyphShape.Style

    var body: some View {
        SpeakerGlyphShape(style: style)
            .fill(.foreground, style: FillStyle(eoFill: true))
            .aspectRatio(SpeakerGlyphShape.aspectRatio, contentMode: .fit)
            .accessibilityHidden(true)
    }
}
