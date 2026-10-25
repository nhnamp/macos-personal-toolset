import AppKit

/// The list of window titles in the middle of the screen. Each row starts with an icon.
/// The panel never becomes the key window, so the frontmost app keeps the keyboard focus.
final class SwitcherPanel {
    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 30
    private static let padding: CGFloat = 8
    private static let iconSize: CGFloat = 16

    private let panel: NSPanel
    private let stack = NSStackView()
    private var rows: [NSView] = []
    private var labels: [NSTextField] = []
    private var iconViews: [NSImageView] = []

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        // Show on the current Space, also over fullscreen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    func show(titles: [String], icons: [NSImage?], selected: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        labels = []
        iconViews = []
        for (title, icon) in zip(titles, icons) {
            let row = makeRow(title: title, icon: icon)
            rows.append(row)
            stack.addArrangedSubview(row)
        }

        let count = CGFloat(titles.count)
        let height = count * Self.rowHeight + max(count - 1, 0) * stack.spacing + 2 * Self.padding
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - Self.width / 2, y: area.midY - height / 2, width: Self.width, height: height),
                       display: false)
        select(selected)
        panel.orderFrontRegardless()
    }

    func select(_ index: Int) {
        for (rowIndex, row) in rows.enumerated() {
            let isSelected = rowIndex == index
            row.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            labels[rowIndex].textColor = isSelected ? .white : .labelColor
        }
    }

    /// Replaces the icon of one row, for example when a website icon is ready.
    func setIcon(_ icon: NSImage?, at index: Int) {
        guard iconViews.indices.contains(index) else { return }
        iconViews[index].image = icon
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makeRow(title: String, icon: NSImage?) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)
        iconViews.append(iconView)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 14)
        // A long title loses its end, not its start.
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(label)
        labels.append(label)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.padding),
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}
