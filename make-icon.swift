// make-icon.swift — draws the maccal app icon (gradient squircle + white calendar
// glyph) and writes the .iconset PNGs. Usage: swift make-icon.swift <out.iconset-dir>
import AppKit

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let full = NSRect(x: 0, y: 0, width: px, height: px)
    let inset = px * 0.085
    let body = full.insetBy(dx: inset, dy: inset)
    let corner = body.width * 0.2237                 // macOS-style rounded square
    let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.13, green: 0.55, blue: 1.00, alpha: 1),   // sky blue
        NSColor(srgbRed: 0.10, green: 0.80, blue: 0.72, alpha: 1),   // teal
    ])!
    grad.draw(in: body, angle: -55)
    NSGraphicsContext.current?.restoreGraphicsState()

    // white calendar glyph, centered
    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.44, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let g = sym.size
        let white = NSImage(size: g)
        white.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: g).fill()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: g), operation: .destinationIn, fraction: 1)
        white.unlockFocus()
        white.draw(in: NSRect(x: (px - g.width)/2, y: (px - g.height)/2, width: g.width, height: g.height))
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
