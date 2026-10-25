import AppKit

// Draws the Toolset app icon into an .iconset folder: a graphite rounded square with the white mark.
// Use Icon/make_icon.sh. It compiles this file with Sources/ToolsetApp/ToolsetGlyph.swift.

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// Draws on a canvas of `size` points. The macOS icon grid is an 824 rounded square in 1024, with a 100 margin.
func drawIcon(size: CGFloat) {
    let scale = size / 1024
    let body = NSBezierPath(roundedRect: NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale),
                            xRadius: 186 * scale, yRadius: 186 * scale)
    NSGradient(colors: [NSColor(white: 0.30, alpha: 1), NSColor(white: 0.12, alpha: 1)])!.draw(in: body, angle: -90)
    let mark = 400 * scale
    NSColor.white.setFill()
    ToolsetGlyph.path(in: NSRect(x: (size - mark) / 2, y: (size - mark) / 2, width: mark, height: mark)).fill()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name).png"))
}
