import AppKit
import ApplicationServices
import HiDPI
import InputMemory
import KeyboardLock
import Mouse
import SpaceProfiles
import SwiftUI
import ToolsetCore
import WindowSwitcher

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    /// Shared by every feature that follows the focused window.
    private let focus = FocusTracker()
    /// Shared by every feature that reacts when a display connects or the display setup changes.
    private let displays = DisplayWatcher()
    private lazy var registry = FeatureRegistry(features: [
        HiDPI(watcher: displays),
        WindowSwitcher(focus: focus),
        SpaceProfiles(watcher: displays),
        InputMemory(focus: focus),
        Mouse(),
        KeyboardLock(),
    ])
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A frozen app must not freeze the toolset. Each Accessibility call waits 0.5 s at most.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        setUpStatusItem()
        installMainMenu()
        registry.startAll()
    }

    /// Opening the app again (from Spotlight or Raycast) shows the settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ToolsetGlyph.menuBarImage
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Builds the menu each time it opens: one section for each feature that runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let features = registry.features.filter(registry.isOn)
        if !registry.isTrusted, features.contains(where: \.needsAccessibility) {
            let waiting = NSMenuItem(title: "Waiting for Accessibility permission", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
            menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        for feature in features where !feature.needsAccessibility || registry.isTrusted {
            menu.addItem(.sectionHeader(title: feature.title))
            feature.menuItems().prefix(3).forEach(menu.addItem)
            menu.addItem(.separator())
        }
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        let quit = NSMenuItem(title: "Quit Toolset", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openAccessibilitySettings() {
        AX.openAccessibilitySettings()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        // While Settings is open, Toolset is a regular app: it has a Dock icon and a Command-Tab entry.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Without the Settings window, Toolset lives in the menu bar only.
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// The app menu shows only while Settings is open. Command-W closes the window, Command-Q quits.
    /// The Edit menu gives Command-C for selected text, for example the Space Profiles activity.
    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit Toolset", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let menuItem = NSMenuItem()
            menuItem.submenu = submenu
            mainMenu.addItem(menuItem)
        }
        NSApp.mainMenu = mainMenu
    }

    /// An AppKit split view with a sidebar item gives the flat look of System Settings:
    /// a floating sidebar, no divider line, and no line under the title bar.
    /// SwiftUI `NavigationSplitView` in a plain window draws both lines.
    private func makeSettingsWindow() -> NSWindow {
        let selection = SettingsSelection()
        let sidebar = NSSplitViewItem(sidebarWithViewController: hosting(SettingsSidebar(registry: registry, selection: selection)))
        sidebar.canCollapse = false
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 200
        let detailView = SettingsDetail(registry: registry, selection: selection) { [weak self] title in
            self?.settingsWindow?.title = title
        }
        let detail = NSSplitViewItem(viewController: hosting(detailView))
        detail.titlebarSeparatorStyle = .none
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(detail)

        let window = NSWindow(contentViewController: split)
        // The detail view sets the title at each later change of the selection.
        window.title = "General"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "ToolsetSettings")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 720, height: 520))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("ToolsetSettings")
        window.center()
        return window
    }

    /// The split view sets the size. The SwiftUI view must not resize the window.
    private func hosting<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }
}
