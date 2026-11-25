// Renders the iPhone app's icon (the "hero front" design): a single saffron bookshelf
// cabinet seen straight-on, built on the menu bar glyph's 18-unit grid (SpeakerGlyph.swift),
// on a deep teal-ink ground. Writes the light, dark and tinted 1024 px icons and the
// Contents.json of a single-size iOS AppIcon with appearances.
//
// Run: swift scripts/make-ios-icon.swift iOS/App/Assets.xcassets/AppIcon.appiconset
// (The Mac app's icon is made by make-icon.swift from build-app.sh; this script is separate.)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-ios-icon.swift <AppIcon.appiconset dir>\n".utf8))
    exit(2)
}
let outDir = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: - Colour helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                         CGFloat(hex & 0xFF) / 255, a])!
}
func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [1, 1, 1, a])! }
func black(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [0, 0, 0, a])! }
func grad(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

struct Palette {
    var bgTop, bgBottom, bgGlow: CGColor
    var cabLight, cabDark: CGColor           // outer bezel (rolled edge)
    var baffleLight, baffleMid, baffleDark: CGColor
    var surroundLight, surroundMid, surroundDark: CGColor
    var coneLight, coneMid, coneDark: CGColor
    var collarLight, collarDark: CGColor
    var domeHi, domeMid, domeDark: CGColor
    var badgeTop, badgeBottom: CGColor
    var shadowStrength: CGFloat
}

let colour = Palette(
    bgTop: rgb(0x18505C), bgBottom: rgb(0x072029), bgGlow: rgb(0x2F7E8C, 0.5),
    cabLight: rgb(0xF8C45C), cabDark: rgb(0xB8711A),
    baffleLight: rgb(0xF7BD4F), baffleMid: rgb(0xEBA636), baffleDark: rgb(0xD48B24),
    surroundLight: rgb(0x464950), surroundMid: rgb(0x2A2C31), surroundDark: rgb(0x111214),
    coneLight: rgb(0xF8E3CB), coneMid: rgb(0xEAC49E), coneDark: rgb(0xC39070),
    collarLight: rgb(0xEDCBA4), collarDark: rgb(0xBE875A),
    domeHi: rgb(0xFBE2A0), domeMid: rgb(0xD39F3E), domeDark: rgb(0x7E5416),
    badgeTop: rgb(0x3A2E20), badgeBottom: rgb(0x221A10),
    shadowStrength: 1)

var dark = colour
dark.bgTop = rgb(0x1C1F24); dark.bgBottom = rgb(0x08090B); dark.bgGlow = rgb(0x6B4A1C, 0.28)
// Slightly deeper cabinet so it glows rather than glares on a dark Home Screen.
dark.baffleLight = rgb(0xEDB047); dark.baffleMid = rgb(0xDD9A30); dark.baffleDark = rgb(0xC27D1F); dark.cabDark = rgb(0x9E5F14)

let tinted = Palette(
    bgTop: rgb(0x000000), bgBottom: rgb(0x000000), bgGlow: rgb(0x000000, 0),
    cabLight: rgb(0xF2F2F2), cabDark: rgb(0x9A9A9A),
    baffleLight: rgb(0xF0F0F0), baffleMid: rgb(0xD6D6D6), baffleDark: rgb(0xBDBDBD),
    surroundLight: rgb(0x5A5A5A), surroundMid: rgb(0x363636), surroundDark: rgb(0x161616),
    coneLight: rgb(0xFFFFFF), coneMid: rgb(0xE2E2E2), coneDark: rgb(0xAFAFAF),
    collarLight: rgb(0xE6E6E6), collarDark: rgb(0x8C8C8C),
    domeHi: rgb(0xFFFFFF), domeMid: rgb(0xD0D0D0), domeDark: rgb(0x7A7A7A),
    badgeTop: rgb(0x3A3A3A), badgeBottom: rgb(0x1C1C1C),
    shadowStrength: 0.6)

// MARK: - Geometry helpers

/// Rounded rect with smoothed (continuous-ish) corners: each corner is one cubic that starts
/// 1.28 r from the corner, which avoids the visible kink of a circular arc meeting a straight edge.
func smoothRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    let e = min(radius * 1.28, min(r.width, r.height) / 2)
    let c: CGFloat = 0.62  // how far toward the corner the control points sit
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + e, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX - e, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY - e),
               control1: CGPoint(x: r.maxX - e + c * e, y: r.maxY), control2: CGPoint(x: r.maxX, y: r.maxY - e + c * e))
    p.addLine(to: CGPoint(x: r.maxX, y: r.minY + e))
    p.addCurve(to: CGPoint(x: r.maxX - e, y: r.minY),
               control1: CGPoint(x: r.maxX, y: r.minY + e - c * e), control2: CGPoint(x: r.maxX - e + c * e, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX + e, y: r.minY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.minY + e),
               control1: CGPoint(x: r.minX + e - c * e, y: r.minY), control2: CGPoint(x: r.minX, y: r.minY + e - c * e))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY - e))
    p.addCurve(to: CGPoint(x: r.minX + e, y: r.maxY),
               control1: CGPoint(x: r.minX, y: r.maxY - e + c * e), control2: CGPoint(x: r.minX + e - c * e, y: r.maxY))
    p.closeSubpath()
    return p
}

/// iOS icon mask stand-in: a superellipse (n = 5) matches the continuous-corner squircle with
/// a ~22.37% corner radius to within a pixel at these sizes.
func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 5, steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let pt = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}
func ring(_ c: CGPoint, _ outer: CGFloat, _ inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addPath(circle(c, outer)); p.addPath(circle(c, inner))
    return p
}

extension CGContext {
    func with(_ body: () -> Void) { saveGState(); body(); restoreGState() }

    func fill(_ path: CGPath, eo: Bool = false, linear g: CGGradient, from a: CGPoint, to b: CGPoint) {
        with {
            addPath(path); if eo { clip(using: .evenOdd) } else { clip() }
            drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// Shadow (or highlight) cast *inside* `path`, as if `path` were a hole in a surface.
    /// The occluding surface itself is drawn far off to the side so only its shadow lands here;
    /// that keeps the anti-aliased clip edge from leaving a dark hairline.
    func innerShadow(_ path: CGPath, eo: Bool = false, offset: CGSize, blur: CGFloat, color: CGColor) {
        with {
            addPath(path); if eo { clip(using: .evenOdd) } else { clip() }
            let far: CGFloat = 30000
            let big = path.boundingBox.insetBy(dx: -blur * 4 - 400, dy: -blur * 4 - 400)
            let hole = CGMutablePath()
            hole.addRect(big); hole.addPath(path)
            var t = CGAffineTransform(translationX: -far, y: 0)
            let moved = hole.copy(using: &t)!
            setShadow(offset: CGSize(width: offset.width + far, height: offset.height), blur: blur, color: color)
            setFillColor(black(1))
            addPath(moved); fillPath(using: .evenOdd)
        }
    }
}

// MARK: - The icon

func drawIcon(_ ctx: CGContext, size S: CGFloat, p: Palette) {
    // Background: deep teal ink, a soft cool glow up and to the left of the speaker.
    ctx.drawLinearGradient(grad([(p.bgTop, 0), (p.bgBottom, 1)]), start: CGPoint(x: S * 0.2, y: S), end: CGPoint(x: S * 0.8, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let glowC = CGPoint(x: S * 0.42, y: S * 0.64)
    ctx.drawRadialGradient(grad([(p.bgGlow, 0), (p.bgGlow.copy(alpha: 0)!, 1)]),
                           startCenter: glowC, startRadius: 0, endCenter: glowC, endRadius: S * 0.62, options: [])

    // Glyph grid -> canvas. Cabinet is 16 units tall; make it 74% of the canvas.
    let u = S * 0.74 / 16
    let ox = S / 2 - 6.5 * u
    let oy = S / 2 + S * 0.018 - 9 * u
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * u, y: oy + y * u) }
    let cab = CGRect(x: ox + 1 * u, y: oy + 1 * u, width: 11 * u, height: 16 * u)
    let cabPath = smoothRect(cab, 2.8 * u)
    let k = p.shadowStrength
    let tl = CGPoint(x: -1, y: 1), br = CGPoint(x: 1, y: -1)   // light direction helpers
    func along(_ c: CGPoint, _ r: CGFloat, _ dir: CGPoint) -> CGPoint { CGPoint(x: c.x + dir.x * r * u, y: c.y + dir.y * r * u) }

    // A pool of light on the shelf under the speaker, so the contact shadow has something to land on.
    ctx.with {
        let c = CGPoint(x: cab.midX, y: cab.minY - 0.2 * u)
        ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 1, y: 0.18)
        ctx.drawRadialGradient(grad([(p.bgGlow.copy(alpha: p.bgGlow.alpha * 0.6)!, 0), (p.bgGlow.copy(alpha: 0)!, 1)]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 8.5 * u, options: [])
    }
    // Contact shadow on the "shelf": a tight dark core and a wide soft falloff.
    ctx.with {
        let c = CGPoint(x: cab.midX + 0.2 * u, y: cab.minY + 0.05 * u)
        ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 1, y: 0.10)
        ctx.drawRadialGradient(grad([(black(0.6 * k), 0), (black(0.28 * k), 0.55), (black(0), 1)]),
                               startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 6.8 * u, options: [])
    }
    // Soft drop shadow from the key light (top-left -> falls down-right).
    ctx.with {
        ctx.setShadow(offset: CGSize(width: 0.35 * u, height: -0.6 * u), blur: 1.8 * u, color: black(0.45 * k))
        ctx.addPath(cabPath); ctx.setFillColor(p.cabDark); ctx.fillPath()
    }

    // Cabinet front: one softly pillowed matte face, its edges rolling away from the key light.
    ctx.fill(cabPath, linear: grad([(p.baffleLight, 0), (p.baffleMid, 0.55), (p.baffleDark, 1)]), from: P(1.5, 17), to: P(12, 1))
    ctx.with {
        ctx.addPath(cabPath); ctx.clip()
        let c = P(3.4, 14.6)
        ctx.drawRadialGradient(grad([(white(0.16), 0), (white(0), 1)]), startCenter: c, startRadius: 0, endCenter: c, endRadius: 8.5 * u, options: [])
    }
    ctx.innerShadow(cabPath, offset: CGSize(width: -0.16 * u, height: 0.24 * u), blur: 0.9 * u, color: p.cabDark.copy(alpha: 0.9)!)
    ctx.innerShadow(cabPath, offset: CGSize(width: 0.10 * u, height: -0.16 * u), blur: 0.45 * u, color: white(0.38))
    // The faintest hint of the inset baffle seam.
    let bi: CGFloat = 0.42
    let baffle = smoothRect(cab.insetBy(dx: bi * u, dy: bi * u), (2.8 - bi) * u)
    ctx.with {
        ctx.translateBy(x: 0.025 * u, y: -0.04 * u)
        ctx.addPath(baffle); ctx.setStrokeColor(white(0.12)); ctx.setLineWidth(0.06 * u); ctx.strokePath()
    }
    ctx.addPath(baffle); ctx.setStrokeColor(black(0.07)); ctx.setLineWidth(0.05 * u); ctx.strokePath()

    // Driver.
    let d = P(6.5, 7.6)
    // Soft recess halo where the surround meets the baffle (heavier on the top-left, in its shade).
    ctx.with {
        ctx.setShadow(offset: CGSize(width: 0.06 * u, height: -0.1 * u), blur: 0.55 * u, color: black(0.45 * k))
        ctx.addPath(circle(d, 4.15 * u)); ctx.setFillColor(p.surroundDark); ctx.fillPath()
    }
    // Thin lit lip on the far (bottom-right) side of the opening.
    ctx.with {
        ctx.addPath(ring(d, 4.30 * u, 4.12 * u)); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(grad([(white(0), 0), (white(0), 0.6), (white(0.14), 1)]),
                               start: along(d, 3, tl), end: along(d, 3, br), options: [])
    }

    // Surround: charcoal rubber roll, 4.15 -> 3.05.
    let surround = ring(d, 4.15 * u, 3.05 * u)
    ctx.with {
        ctx.addPath(surround); ctx.clip(using: .evenOdd)
        ctx.drawRadialGradient(grad([(p.surroundDark, 0), (p.surroundMid, 0.22), (p.surroundLight, 0.5), (p.surroundMid, 0.8), (p.surroundDark, 1)]),
                               startCenter: d, startRadius: 3.05 * u, endCenter: d, endRadius: 4.15 * u, options: [])
        // Directional light on the roll.
        ctx.drawLinearGradient(grad([(white(0.14), 0), (white(0), 0.5), (black(0.30), 1)]),
                               start: along(d, 3, tl), end: along(d, 3, br), options: [])
        // Corrugated ribs: each rib's flanks catch or lose the key light depending on which way
        // they face, plus a narrow occluded groove between ribs.
        let ribs: CGFloat = 30, n = 900
        for i in 0..<n {
            let a0 = CGFloat(i) / CGFloat(n) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(n) * 2 * .pi + 0.001
            let a = (a0 + a1) / 2
            let t = sin(a + .pi / 4)          // tangent . light
            let c = cos(ribs * a), s = sin(ribs * a)
            let v = 0.75 * c * t - 0.55 * pow(max(0, -s), 4) + 0.12 * max(0, s)
            let col = v > 0 ? white(0.13 * v) : black(0.42 * -v)
            ctx.move(to: CGPoint(x: d.x + cos(a0) * 3.0 * u, y: d.y + sin(a0) * 3.0 * u))
            ctx.addLine(to: CGPoint(x: d.x + cos(a0) * 4.2 * u, y: d.y + sin(a0) * 4.2 * u))
            ctx.addLine(to: CGPoint(x: d.x + cos(a1) * 4.2 * u, y: d.y + sin(a1) * 4.2 * u))
            ctx.addLine(to: CGPoint(x: d.x + cos(a1) * 3.0 * u, y: d.y + sin(a1) * 3.0 * u))
            ctx.closePath(); ctx.setFillColor(col); ctx.fillPath()
        }
        // Ribs fade out where the roll meets the baffle and the cone.
        ctx.drawRadialGradient(grad([(p.surroundDark, 0), (p.surroundDark.copy(alpha: 0)!, 0.28), (p.surroundDark.copy(alpha: 0)!, 0.72), (p.surroundDark, 1)]),
                               startCenter: d, startRadius: 3.05 * u, endCenter: d, endRadius: 4.15 * u, options: [])
    }
    ctx.innerShadow(circle(d, 4.15 * u), offset: CGSize(width: 0.1 * u, height: -0.16 * u), blur: 0.35 * u, color: black(0.45 * k))

    // Cone: champagne dish, 3.05.
    let cone = circle(d, 3.05 * u)
    ctx.with {
        ctx.addPath(cone); ctx.clip()
        let hc = CGPoint(x: d.x + 0.5 * u, y: d.y - 0.6 * u)
        ctx.drawRadialGradient(grad([(p.coneLight, 0), (p.coneMid, 0.62), (p.coneDark, 1)]),
                               startCenter: hc, startRadius: 0, endCenter: d, endRadius: 3.1 * u, options: [.drawsAfterEndLocation])
        // Anisotropic metal sheen: two soft lobes along the light axis, darker across it.
        let n = 180
        for i in 0..<n {
            let a0 = CGFloat(i) / CGFloat(n) * 2 * .pi, a1 = CGFloat(i + 1) / CGFloat(n) * 2 * .pi + 0.002
            let m = cos(2 * ((a0 + a1) / 2 - 3 * .pi / 4))
            let col = m > 0 ? white(0.16 * m * m) : black(0.07 * m * m)
            ctx.move(to: d)
            ctx.addLine(to: CGPoint(x: d.x + cos(a0) * 3.2 * u, y: d.y + sin(a0) * 3.2 * u))
            ctx.addLine(to: CGPoint(x: d.x + cos(a1) * 3.2 * u, y: d.y + sin(a1) * 3.2 * u))
            ctx.closePath(); ctx.setFillColor(col); ctx.fillPath()
        }
    }
    ctx.innerShadow(cone, offset: CGSize(width: 0.12 * u, height: -0.2 * u), blur: 0.6 * u, color: black(0.40 * k))

    // Collar around the tweeter: a shallow champagne bowl, 1.75.
    let collar = circle(d, 1.75 * u)
    ctx.with {
        ctx.addPath(collar); ctx.clip()
        ctx.drawRadialGradient(grad([(p.collarDark, 0), (p.collarLight, 1)]), startCenter: d, startRadius: 1.05 * u,
                               endCenter: d, endRadius: 1.75 * u, options: [])
        ctx.drawLinearGradient(grad([(p.collarDark.copy(alpha: 0.25)!, 0), (white(0.12), 1)]), start: along(d, 1.3, tl), end: along(d, 1.3, br), options: [])
    }
    ctx.innerShadow(collar, offset: CGSize(width: 0.06 * u, height: -0.1 * u), blur: 0.28 * u, color: black(0.28 * k))
    // Fine groove where the dome sits.
    ctx.addPath(circle(d, 1.11 * u)); ctx.setFillColor(p.domeDark.copy(alpha: 0.75)!); ctx.fillPath()

    // Tweeter dome: gold, 1.05.
    let dome = circle(d, 1.05 * u)
    ctx.with {
        ctx.addPath(dome); ctx.clip()
        let hc = CGPoint(x: d.x - 0.35 * u, y: d.y + 0.35 * u)
        ctx.drawRadialGradient(grad([(p.domeHi, 0), (p.domeMid, 0.5), (p.domeDark, 1)]),
                               startCenter: hc, startRadius: 0, endCenter: d, endRadius: 1.1 * u, options: [.drawsAfterEndLocation])
        let sc = CGPoint(x: d.x - 0.38 * u, y: d.y + 0.42 * u)
        ctx.drawRadialGradient(grad([(white(0.45), 0), (white(0), 1)]), startCenter: sc, startRadius: 0, endCenter: sc, endRadius: 0.4 * u, options: [])
    }

    // Badge plate near the top (no text): a small recessed dark window.
    let badge = smoothRect(CGRect(x: ox + 5.2 * u, y: oy + 13.6 * u, width: 2.6 * u, height: 1.1 * u), 0.55 * u)
    ctx.fill(badge, linear: grad([(p.badgeTop, 0), (p.badgeBottom, 1)]), from: P(6.5, 14.7), to: P(6.5, 13.6))
    ctx.innerShadow(badge, offset: CGSize(width: 0.03 * u, height: -0.07 * u), blur: 0.14 * u, color: black(0.45))
    // Soft satin sheen across the plate's upper half.
    ctx.with {
        ctx.addPath(badge); ctx.clip()
        ctx.drawLinearGradient(grad([(white(0.10), 0), (white(0), 1)]), start: P(6.5, 14.6), end: P(6.5, 14.1), options: [])
    }
    // Lit lower lip.
    ctx.with {
        ctx.addPath(smoothRect(CGRect(x: ox + 5.2 * u, y: oy + 13.6 * u, width: 2.6 * u, height: 1.1 * u).insetBy(dx: -0.06 * u, dy: -0.06 * u), 0.61 * u))
        ctx.addPath(badge); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(grad([(white(0), 0), (white(0.35), 1)]), start: P(6.5, 14.2), end: P(6.5, 13.5), options: [])
    }
}

// MARK: - Output

func makeContext(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func writePNG(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(name)")
}

func renderIcon(_ p: Palette) -> CGImage {
    let ctx = makeContext(1024, 1024, opaque: true)
    drawIcon(ctx, size: 1024, p: p)
    return ctx.makeImage()!
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let icons: [(file: String, palette: Palette, appearance: String?)] = [
    ("AppIcon-1024.png", colour, nil),
    ("AppIcon-Dark-1024.png", dark, "dark"),
    ("AppIcon-Tinted-1024.png", tinted, "tinted"),
]
for icon in icons { writePNG(renderIcon(icon.palette), icon.file) }

// Single-size iOS icon: one 1024 px image per appearance, the system scales the rest.
let images = icons.map { icon -> String in
    let appearance = icon.appearance.map {
        "\n      \"appearances\" : [\n        {\n          \"appearance\" : \"luminosity\",\n          \"value\" : \"\($0)\"\n        }\n      ],"
    } ?? ""
    return "    {\(appearance)\n      \"filename\" : \"\(icon.file)\",\n      \"idiom\" : \"universal\",\n      \"platform\" : \"ios\",\n      \"size\" : \"1024x1024\"\n    }"
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
try contents.write(toFile: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json").path, atomically: true, encoding: .utf8)
print("wrote \(icons.map(\.file).joined(separator: ", ")) and Contents.json to \(outDir)")
