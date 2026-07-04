// make-icon.swift — draws the maccal app icon: a gradient squircle carrying the
// menu-bar identity (a sync ring around a mini calendar) in white, so the app
// icon and the tray glyph are the same mark. Usage: swift make-icon.swift <dir>
import AppKit

/// An SF Symbol filled solid white (so it reads on the gradient).
func whiteSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let g = sym.size
    let white = NSImage(size: g)
    white.lockFocus()
    NSColor.white.setFill(); NSRect(origin: .zero, size: g).fill()
    sym.draw(at: .zero, from: NSRect(origin: .zero, size: g), operation: .destinationIn, fraction: 1)
    white.unlockFocus()
    return white
}

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: px, height: px)
    let body = full.insetBy(dx: px * 0.085, dy: px * 0.085)
    let corner = body.width * 0.2237                 // macOS-style rounded square
    let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0.13, green: 0.55, blue: 1.00, alpha: 1),   // sky blue
        NSColor(srgbRed: 0.10, green: 0.80, blue: 0.72, alpha: 1),   // teal
    ])!.draw(in: body, angle: -55)
    NSGraphicsContext.current?.restoreGraphicsState()

    // sync ring (circular arrows), white, large — the menu-bar identity.
    if let ring = whiteSymbol("arrow.triangle.2.circlepath", pointSize: px * 0.56, weight: .light) {
        let g = ring.size
        ring.draw(in: NSRect(x: (px - g.width) / 2, y: (px - g.height) / 2, width: g.width, height: g.height))
    }
    // mini calendar (square + header bar + 2x2 day dots), white, centred in the ring.
    if let sq = whiteSymbol("square", pointSize: px * 0.24, weight: .regular) {
        let g = sq.size
        let ox = (px - g.width) / 2, oy = (px - g.height) / 2
        sq.draw(in: NSRect(x: ox, y: oy, width: g.width, height: g.height))
        NSColor.white.setFill()
        let barH = px * 0.020                          // thicken the top edge (header hint)
        NSBezierPath(rect: NSRect(x: ox + g.width * 0.14, y: oy + g.height - barH - px * 0.012,
                                  width: g.width * 0.72, height: barH)).fill()
        let dot = px * 0.024                            // 2x2 day marks
        let cx = ox + g.width / 2, cy = oy + g.height / 2 - px * 0.006
        let gap = px * 0.058
        for dx in [-gap / 2, gap / 2] {
            for dy in [-gap / 2, gap / 2] {
                NSBezierPath(ovalIn: NSRect(x: cx + dx - dot / 2, y: cy + dy - dot / 2, width: dot, height: dot)).fill()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let specs: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in specs {
    let rep = drawIcon(CGFloat(px))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
print("wrote \(specs.count) PNGs to \(outDir)")
