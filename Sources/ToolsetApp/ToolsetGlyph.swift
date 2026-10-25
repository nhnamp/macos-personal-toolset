import AppKit

/// The Toolset mark: four tiles in a square, the top-right tile as an outline.
/// The menu bar icon and the app icon (`Icon/make_icon`) use the same shape.
enum ToolsetGlyph {
    /// The shape in a square rect. Fill it with the even-odd rule, so the outline tile stays open.
    static func path(in rect: NSRect) -> NSBezierPath {
        let tile = rect.width * 0.42
        let gap = rect.width * 0.16
        let radius = tile * 0.26
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        for (column, row) in [(0, 0), (1, 0), (0, 1)] {
            let origin = NSPoint(x: rect.minX + CGFloat(column) * (tile + gap), y: rect.minY + CGFloat(row) * (tile + gap))
            path.append(NSBezierPath(roundedRect: NSRect(origin: origin, size: NSSize(width: tile, height: tile)), xRadius: radius, yRadius: radius))
        }
        let outline = NSRect(x: rect.minX + tile + gap, y: rect.minY + tile + gap, width: tile, height: tile)
        let line = tile * 0.17
        path.append(NSBezierPath(roundedRect: outline, xRadius: radius, yRadius: radius))
        path.append(NSBezierPath(roundedRect: outline.insetBy(dx: line, dy: line), xRadius: radius - line * 0.6, yRadius: radius - line * 0.6))
        return path
    }

    /// The menu bar icon. A template image follows the light or dark menu bar.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSColor.black.setFill()
            path(in: bounds.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Toolset"
        return image
    }()
}
