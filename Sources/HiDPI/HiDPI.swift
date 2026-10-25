import AppKit
import SwiftUI
import ToolsetCore

/// The saved HiDPI size of each display, keyed by vendor, model, and serial number.
public final class HiDPISettings: ObservableObject {
    @Published public private(set) var sizes: [String: HiDPISize] { didSet { save() } }

    private let defaults: UserDefaults
    private let key = "HiDPI"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sizes = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: HiDPISize].self, from: $0) } ?? [:]
    }

    func set(_ size: HiDPISize?, for displayKey: String) {
        sizes[displayKey] = size
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(sizes), forKey: key)
    }
}

/// Selects a HiDPI mode on external displays, also the modes that System Settings does not show.
/// It applies the saved size at start and each time a display connects.
/// When the feature turns off, the displays keep their current mode.
public final class HiDPI: NSObject, ObservableObject, ToolsetFeature {
    public let id = "hidpi"
    public let title = "HiDPI"
    public let summary = "Sharp text on external displays, with the HiDPI sizes that macOS hides."
    public let needsAccessibility = false

    public let settings: HiDPISettings
    @Published public private(set) var displays: [ExternalDisplay] = []

    private let watcher: DisplayWatcher
    private var isRunning = false

    /// The host passes the toolset's shared display watcher.
    public init(watcher: DisplayWatcher, settings: HiDPISettings = HiDPISettings()) {
        self.watcher = watcher
        self.settings = settings
        super.init()
        watcher.subscribeToConnections { [weak self] display in self?.connected(display) }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        watcher.start()
        for display in DisplayModes.externalDisplays() { applySavedSize(to: display.id) }
        refresh()
    }

    public func stop() {
        guard isRunning else { return }
        watcher.stop()
        isRunning = false
    }

    /// Reads the displays and their current modes again.
    public func refresh() {
        displays = DisplayModes.externalDisplays()
    }

    /// Selects the size now and saves it for this display. Nil stops the management of the display.
    public func choose(_ size: HiDPISize?, for display: ExternalDisplay) {
        settings.set(size, for: display.key)
        if let size { DisplayModes.select(size, on: display.id) }
        refresh()
    }

    public func menuItems() -> [NSMenuItem] {
        refresh()
        guard PrivateAPIs.canSetHiddenModes else { return [disabledItem("Not available on this macOS")] }
        guard !displays.isEmpty else { return [disabledItem("No external display")] }
        return displays.prefix(3).map { display in
            let item = NSMenuItem(title: "\(display.name): \(display.currentText)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for size in display.sizes {
                let choice = NSMenuItem(title: size.label, action: #selector(menuChoice(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = (display.id, size)
                choice.state = size == display.currentSize ? .on : .off
                submenu.addItem(choice)
            }
            item.submenu = submenu
            return item
        }
    }

    public func makeSettingsSections() -> AnyView {
        AnyView(HiDPISettingsView(hidpi: self, settings: settings))
    }

    @objc private func menuChoice(_ sender: NSMenuItem) {
        guard let (id, size) = sender.representedObject as? (CGDirectDisplayID, HiDPISize),
              let display = displays.first(where: { $0.id == id }) else { return }
        choose(size, for: display)
    }

    private func connected(_ display: CGDirectDisplayID) {
        guard isRunning, CGDisplayIsBuiltin(display) == 0 else { return }
        applySavedSize(to: display)
        refresh()
    }

    private func applySavedSize(to display: CGDirectDisplayID) {
        guard let size = settings.sizes[DisplayModes.key(of: display)] else { return }
        if !DisplayModes.select(size, on: display) {
            NSLog("HiDPI: display \(display) has no \(size.label) HiDPI mode")
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
