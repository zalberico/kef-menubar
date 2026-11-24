// Renders Resources/AppIcon.icns: a graphite squircle with a white pair of the app's
// speaker glyphs. It needs SpeakerGlyph, so build-app.sh runs it concatenated:
//   cat Sources/KEFMenuBar/SpeakerGlyph.swift scripts/make-icon.swift > /tmp/icon.swift
//   swift /tmp/icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, continuous corners.
    let inset = size * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    path.fill()
    context.restoreGState()

    path.addClip()
    NSGradient(colors: [NSColor(calibratedWhite: 0.30, alpha: 1), NSColor(calibratedWhite: 0.09, alpha: 1)])!
        .draw(in: body, angle: -90)
    // Soft top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // A pair of the app's own bookshelf cabinets (SpeakerGlyph), in white.
    let glyph = SpeakerGlyph.image(.on, height: body.height * 0.46)
    let white = NSImage(size: glyph.size, flipped: false) { r in
        glyph.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
    }
    let gap = body.width * 0.06
    let pairWidth = white.size.width * 2 + gap
    for i in 0..<2 {
        let x = body.midX - pairWidth / 2 + CGFloat(i) * (white.size.width + gap)
        white.draw(in: CGRect(x: x, y: body.midY - white.size.height / 2, width: white.size.width, height: white.size.height))
    }
    // Hairline edge.
    NSColor.white.withAlphaComponent(0.10).setStroke()
    path.lineWidth = max(1, size / 512)
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
exit(iconutil.terminationStatus)
