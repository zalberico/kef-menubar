import AppKit

/// The app's own speaker glyph: a bookshelf cabinet with KEF's concentric Uni-Q driver
/// (tweeter in the middle of the woofer), drawn as a template image so it follows the
/// menu bar's light or dark appearance. Deliberately unlike the system speaker symbols.
enum SpeakerGlyph {
    enum Style {
        /// Playing; `level` (0…1) fills the slim bar beside the cabinet.
        case on
        case muted
        case standby
        case offline
    }

    /// - Parameter height: point height (the menu bar uses 18).
    static func image(_ style: Style, level: Double? = nil, height: CGFloat = 18) -> NSImage {
        let showsLevel = style == .on && level != nil
        let width = (showsLevel ? 17 : 13) * height / 18
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: height / 18, y: height / 18)
            draw(style, level: showsLevel ? min(max(level ?? 0, 0), 1) : nil)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch style {
        case .on: "KEF speaker on"
        case .muted: "KEF speaker muted"
        case .standby: "KEF speaker in standby"
        case .offline: "KEF speaker offline"
        }
        return image
    }

    // Geometry on an 18-unit grid.
    private static let cabinet = NSRect(x: 1, y: 1, width: 11, height: 16)
    private static let driver = NSPoint(x: 6.5, y: 7.6)

    private static func circle(_ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: driver.x - radius, y: driver.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private static func cabinetPath(inset: CGFloat = 0) -> NSBezierPath {
        let rect = cabinet.insetBy(dx: inset, dy: inset)
        return NSBezierPath(roundedRect: rect, xRadius: 2.8 - inset, yRadius: 2.8 - inset)
    }

    private static func draw(_ style: Style, level: Double?) {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.set()
        switch style {
        case .on, .muted:
            // Solid cabinet with the driver cut out of it: surround ring, cone, tweeter.
            cabinetPath().fill()
            context.compositingOperation = .destinationOut
            ring(outer: 4.15, inner: 3.05)
            ring(outer: 1.75, inner: 1.05)
            // A small badge at the top, like the KEF logo plate.
            NSBezierPath(roundedRect: NSRect(x: 5.2, y: 13.6, width: 2.6, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()
            context.compositingOperation = .sourceOver
            if style == .muted { slash(context) }
        case .standby:
            // Outline only: the speaker is asleep.
            let outline = cabinetPath(inset: 0.65)
            outline.lineWidth = 1.3
            outline.stroke()
            let surround = circle(3.6)
            surround.lineWidth = 1.2
            surround.stroke()
            circle(1.0).fill()
        case .offline:
            // Outline with an exclamation mark where the driver would be.
            let outline = cabinetPath(inset: 0.65)
            outline.lineWidth = 1.3
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 5.75, y: 6.6, width: 1.5, height: 6.6), xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(ovalIn: NSRect(x: 5.65, y: 3.4, width: 1.7, height: 1.7)).fill()
        }
        if let level { levelBar(level) }
    }

    private static func ring(outer: CGFloat, inner: CGFloat) {
        let path = circle(outer)
        path.append(circle(inner).reversed)
        path.fill()
    }

    private static func slash(_ context: NSGraphicsContext) {
        let from = NSPoint(x: 1.0, y: 16.6), to = NSPoint(x: 12.0, y: 1.4)
        let gap = NSBezierPath()
        gap.move(to: from)
        gap.line(to: to)
        gap.lineWidth = 3.4
        gap.lineCapStyle = .round
        context.compositingOperation = .destinationOut
        gap.stroke()
        context.compositingOperation = .sourceOver
        let line = NSBezierPath()
        line.move(to: from)
        line.line(to: to)
        line.lineWidth = 1.4
        line.lineCapStyle = .round
        line.stroke()
    }

    /// Slim vertical level meter to the right of the cabinet.
    private static func levelBar(_ level: Double) {
        let track = NSRect(x: 14, y: 1.5, width: 2.2, height: 15)
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.1, yRadius: 1.1).fill()
        guard level > 0 else { return }
        let height = max(track.width, track.height * level)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: height),
                     xRadius: 1.1, yRadius: 1.1).fill()
    }
}
