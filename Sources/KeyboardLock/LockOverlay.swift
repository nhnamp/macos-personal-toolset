import AppKit

/// A lock symbol in a circle, with a progress ring and a caption under it.
/// The hold indicator and the lock screen both use this view.
final class LockRingView: NSView {
    static let diameter: CGFloat = 120

    /// 0...1, or nil for no ring.
    var progress: Double? { didSet { needsDisplay = true } }
    var caption = "" { didSet { needsDisplay = true } }
    var isLocked = false { didSet { needsDisplay = true } }
    /// Called when the user clicks the circle.
    var onClick: (() -> Void)?

    private var circleRect: NSRect {
        NSRect(x: bounds.midX - Self.diameter / 2, y: bounds.midY - Self.diameter / 2 + 20, width: Self.diameter, height: Self.diameter)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if NSBezierPath(ovalIn: circleRect).contains(point) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = circleRect
        NSColor(white: 0.15, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let ringRect = circle.insetBy(dx: 4, dy: 4)
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = 6
        NSColor(white: 1, alpha: 0.15).setStroke()
        track.stroke()
        if let progress, progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ringRect.midX, y: ringRect.midY), radius: ringRect.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * min(progress, 1), clockwise: true)
            arc.lineWidth = 6
            arc.lineCapStyle = .round
            NSColor.white.setStroke()
            arc.stroke()
        }

        let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .semibold).applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: isLocked ? "lock.fill" : "lock.open.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2, width: size.width, height: size.height))
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        // A shadow keeps the text clear on a bright or busy screen.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.9)
        shadow.shadowBlurRadius = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow,
        ]
        caption.draw(in: NSRect(x: 0, y: circle.minY - 56, width: bounds.width, height: 44), withAttributes: attributes)
    }
}

/// The windows of Keyboard Lock: a small indicator while the user holds the shortcut,
/// and a dark window on each display while the keyboard is locked.
final class LockOverlay {
    private var holdPanel: NSPanel?
    private var lockPanels: [NSPanel] = []

    // MARK: Hold indicator

    func showHold(progress: Double?, caption: String) {
        if holdPanel == nil {
            let screen = Self.screenWithMouse()
            let size = NSSize(width: 360, height: 220)
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
            let panel = Self.makePanel(frame: frame)
            panel.ignoresMouseEvents = true
            let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            backdrop.material = .hudWindow
            backdrop.state = .active
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = 24
            backdrop.addSubview(LockRingView(frame: backdrop.bounds))
            panel.contentView = backdrop
            panel.orderFrontRegardless()
            holdPanel = panel
        }
        guard let ring = holdPanel?.contentView?.subviews.first as? LockRingView else { return }
        ring.progress = progress
        ring.caption = caption
    }

    func hideHold() {
        holdPanel?.orderOut(nil)
        holdPanel = nil
    }

    // MARK: Lock screen

    func showLock(onClick: @escaping () -> Void) {
        hideHold()
        lockPanels = NSScreen.screens.map { screen in
            let panel = Self.makePanel(frame: screen.frame)
            panel.backgroundColor = NSColor(white: 0, alpha: 0.6)
            let ring = LockRingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            ring.isLocked = true
            ring.onClick = onClick
            panel.contentView = ring
            panel.orderFrontRegardless()
            return panel
        }
        updateLock(progress: nil, caption: Self.lockedCaption)
    }

    static let lockedCaption = "The keyboard is locked.\nClick the lock to unlock it."

    func updateLock(progress: Double?, caption: String) {
        for case let ring as LockRingView in lockPanels.map(\.contentView) {
            ring.progress = progress
            ring.caption = caption
        }
    }

    func hideLock() {
        lockPanels.forEach { $0.orderOut(nil) }
        lockPanels = []
    }

    // MARK: Helpers

    /// A panel above all windows, on every Space and over full-screen apps. A click does not activate Toolset.
    private static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
