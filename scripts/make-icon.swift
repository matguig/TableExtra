// Renders the TableExtra app icon into an .iconset folder from the artwork in Resources/AppIcon-source.png.
// The artwork is a 1024×1024 render of the icon on an opaque white background; this crops its rounded
// square, re-masks it on a transparent canvas following the macOS icon grid (824pt body, 100pt margin)
// and adds the standard soft drop shadow.
// Usage: swift scripts/make-icon.swift <output.iconset> [source.png]
import AppKit

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "AppIcon.iconset")
let sourcePath = args.count > 2 ? args[2] : "Resources/AppIcon-source.png"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

guard let source = NSImage(contentsOfFile: sourcePath)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}
// Rounded square of the artwork (measured on the 1024px source), inset a few pixels to drop its anti-aliased rim.
let scale = CGFloat(source.width) / 1024
let crop = CGRect(x: 102 * scale, y: 106 * scale, width: 820 * scale, height: 820 * scale)
guard let body = source.cropping(to: crop) else { exit(1) }

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / 1024
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    // Shadow (skipped at tiny sizes where it only blurs the edge).
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(body, in: rect)
    ctx.restoreGState()
    // Hairline rim so the light body stays defined on light backgrounds.
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(max(1, 2 * s))
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for mult in [1, 2] {
        let px = base * mult
        let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
