import AppKit

/// The switch logic. Option-Tab opens the list of the frontmost app's windows.
/// Each Tab moves the selection. When Option goes up, the selected window gets the focus.
final class Switcher {
    private let store: WindowStore
    private let hotkeys: Hotkeys
    private let panel = SwitcherPanel()
    private let icons = WindowIcons()
    /// The app of the switch in progress. It is nil when no switch is in progress.
    private var app: NSRunningApplication?
    private var windows: [SwitcherWindow] = []
    private var selected = 0

    init(store: WindowStore, hotkeys: Hotkeys) {
        self.store = store
        self.hotkeys = hotkeys
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeys.onOptionUp = { [weak self] in self?.finish(focus: true) }
    }

    private func handle(_ action: Hotkeys.Action) {
        switch action {
        case .next: app == nil ? start(step: 1) : move(by: 1)
        case .previous: app == nil ? start(step: -1) : move(by: -1)
        case .cancel: finish(focus: false)
        }
    }

    private func start(step: Int) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != getpid() else { return }
        let list = store.windows(of: frontApp)
        guard !list.isEmpty else {
            NSSound.beep()
            return
        }
        // The first window has the focus, so the first Tab selects the window before it in focus order.
        let first = list.count == 1 ? 0 : (step > 0 ? 1 : list.count - 1)

        // A fast tap: Option is already up when the hot key event arrives.
        // Switch at once. Do not show the panel, because no Option release comes to close it.
        guard Hotkeys.isOptionDown else {
            Focus.focus(list[first], of: frontApp)
            return
        }

        app = frontApp
        windows = list
        selected = first
        panel.show(titles: list.map(\.title), icons: icons.immediateIcons(for: list, of: frontApp), selected: first)
        loadFavicons()
        hotkeys.setCancelEnabled(true)
        store.searchIfNeeded(for: frontApp) { [weak self] in self?.reload() }
    }

    private func move(by step: Int) {
        guard !windows.isEmpty else { return }
        selected = (selected + step + windows.count) % windows.count
        panel.select(selected)
    }

    /// Adds the windows that the background search found. The selection stays on the same window.
    private func reload() {
        guard let app, !windows.isEmpty else { return }
        let current = windows[selected]
        let list = store.windows(of: app)
        guard !list.isEmpty else { return }
        windows = list
        selected = list.firstIndex { isSame($0, current) } ?? min(selected, list.count - 1)
        panel.show(titles: list.map(\.title), icons: icons.immediateIcons(for: list, of: app), selected: selected)
        loadFavicons()
    }

    /// For a browser, replaces the app icons with the website icons when the background lookup ends.
    private func loadFavicons() {
        guard let app, WindowIcons.hasFavicons(app) else { return }
        let list = windows
        icons.loadFavicons(for: list, of: app) { [weak self] favicons in
            // The list can change while the lookup runs. Then the next lookup updates the icons.
            guard let self, self.app == app, self.windows.count == list.count,
                  zip(self.windows, list).allSatisfy({ self.isSame($0, $1) }) else { return }
            for (index, favicon) in favicons.enumerated() {
                self.panel.setIcon(favicon ?? app.icon, at: index)
            }
        }
    }

    private func finish(focus: Bool) {
        guard let app, !windows.isEmpty else { return }
        let target = windows[selected]
        self.app = nil
        windows = []
        panel.hide()
        hotkeys.setCancelEnabled(false)
        if focus {
            Focus.focus(target, of: app)
        }
    }

    private func isSame(_ a: SwitcherWindow, _ b: SwitcherWindow) -> Bool {
        if let idA = a.windowId, let idB = b.windowId { return idA == idB }
        return CFEqual(a.element, b.element)
    }
}
