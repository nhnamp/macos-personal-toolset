import AppKit
import SwiftUI
import ToolsetCore

/// Option-Tab lists the windows of the frontmost app on all Spaces. The release of Option focuses the selected window.
/// Command-Tab still changes the app, as before. This feature was the separate app OptionTab.
public final class WindowSwitcher: NSObject, ObservableObject, ToolsetFeature {
    public let id = "window-switcher"
    public let title = "Window Switcher"
    public let summary = "Option-Tab switches between the windows of the frontmost app."
    public let needsAccessibility = true

    static let altTabBundleId = "com.lwouis.alt-tab-macos"

    private let focus: FocusTracker
    private let store = WindowStore()
    private let hotkeys = Hotkeys()
    private var switcher: Switcher?
    private var lastPid: pid_t?
    private var isRunning = false

    /// The host passes the toolset's shared focus tracker.
    public init(focus: FocusTracker) {
        self.focus = focus
        super.init()
        focus.subscribe { [weak self] window in self?.focusChanged(to: window) }
    }

    public func start() {
        guard !isRunning else { return }
        // The event tap for the Option release needs the Accessibility permission.
        guard hotkeys.start() else {
            NSLog("Window Switcher: the event tap did not start")
            return
        }
        isRunning = true
        switcher = Switcher(store: store, hotkeys: hotkeys)
        focus.start()
    }

    public func stop() {
        guard isRunning else { return }
        hotkeys.stop()
        switcher = nil
        focus.stop()
        lastPid = nil
        isRunning = false
    }

    public func menuItems() -> [NSMenuItem] {
        var items = [disabledItem(PrivateAPIs.canFindWindowsOnAllSpaces ? "Option-Tab: windows on all Spaces" : "Option-Tab: windows on this Space only")]
        if Self.isAltTabRunning {
            items.append(disabledItem("AltTab also uses Option-Tab. Quit AltTab."))
        }
        if WindowIcons.needsEdgeDataAccess {
            let item = NSMenuItem(title: "Allow Website Icons for Edge…", action: #selector(openFullDiskAccessSettings), keyEquivalent: "")
            item.target = self
            items.append(item)
        }
        return items
    }

    public func makeSettingsSections() -> AnyView {
        AnyView(WindowSwitcherSettingsView(openFullDiskAccess: { [weak self] in self?.openFullDiskAccessSettings() }))
    }

    static var isAltTabRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: altTabBundleId).isEmpty
    }

    /// Records the focus order, and searches the windows on other Spaces when the user changes the app.
    /// The search runs now, so the windows are ready before the next Option-Tab.
    private func focusChanged(to window: FocusedWindow) {
        guard isRunning, window.pid != getpid() else { return }
        if window.windowID != 0 {
            store.noteFocused(pid: window.pid, windowId: window.windowID)
        }
        guard window.pid != lastPid, let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        lastPid = window.pid
        store.searchIfNeeded(for: app) {}
    }

    @objc func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
