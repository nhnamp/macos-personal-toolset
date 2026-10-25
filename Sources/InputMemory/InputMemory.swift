import AppKit
import Carbon
import SwiftUI
import ToolsetCore

/// Remembers the input source of each window, and selects it again when the window gets the focus.
///
/// A window that has no memory yet starts with, in this order:
/// 1. the rule of its app,
/// 2. the source last used in another window of the same app (for example, a new tab window or a Save sheet),
/// 3. the default source in the settings, or the current source when the default is "Keep current".
public final class InputMemory: ObservableObject, ToolsetFeature {
    public let id = "input-memory"
    public let title = "Input Memory"
    public let summary = "Keeps the input source of each window."
    public let needsAccessibility = true

    public let settings: InputMemorySettings
    @Published public private(set) var rememberedCount = 0

    private let focus: FocusTracker
    private var isRunning = false
    private var focused: FocusedWindow?
    private var windowSources: [FocusedWindow: String] = [:] { didSet { rememberedCount = windowSources.count } }
    private var appSources: [pid_t: String] = [:]
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    /// Set INPUTMEMORY_LOG=1 to print each focus change and selection, for tests from Terminal.
    private let logs = ProcessInfo.processInfo.environment["INPUTMEMORY_LOG"] == "1"

    /// The host passes the toolset's shared focus tracker. The tracker can serve other features too.
    public init(focus: FocusTracker, settings: InputMemorySettings = InputMemorySettings()) {
        self.focus = focus
        self.settings = settings
        focus.subscribe { [weak self] window in self?.focusChanged(to: window) }
    }

    public func menuItems() -> [NSMenuItem] {
        pruneClosedWindows()
        let status = NSMenuItem(title: rememberedCount == 1 ? "1 window remembered" : "\(rememberedCount) windows remembered", action: nil, keyEquivalent: "")
        status.isEnabled = false
        return [status]
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let distributed = DistributedNotificationCenter.default()
        let sourceChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        tokens.append((distributed, distributed.addObserver(forName: sourceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.recordCurrentSource()
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.forget(pid: app.processIdentifier)
        }))
        focus.start()
        focused = focus.current
    }

    public func stop() {
        guard isRunning else { return }
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        focus.stop()
        isRunning = false
        focused = nil
        // The memory goes out of date while the feature is off.
        forgetAll()
    }

    public func forgetAll() {
        windowSources.removeAll()
        appSources.removeAll()
    }

    /// Drops the windows that were closed. The host calls this before it shows the count.
    public func pruneClosedWindows() {
        guard let info = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return }
        let open = Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        windowSources = windowSources.filter { $0.key.windowID == 0 || open.contains($0.key.windowID) }
    }

    public func makeSettingsSections() -> AnyView {
        AnyView(InputMemorySettingsView(memory: self, settings: settings))
    }

    // MARK: - Events

    private func focusChanged(to window: FocusedWindow) {
        guard isRunning else { return }
        // Saves the source of the window that loses the focus. This also covers a change
        // whose notification has not arrived yet.
        recordCurrentSource()
        focused = window
        // The toolset's own windows keep the current source.
        guard window.pid != ProcessInfo.processInfo.processIdentifier else { return }
        let target = source(for: window)
        log("focus pid=\(window.pid) window=\(window.windowID) -> \(target ?? "keep")")
        guard let target, target != InputSources.currentID() else { return }
        InputSources.select(target)
    }

    private func source(for window: FocusedWindow) -> String? {
        windowSources[window]
            ?? settings.rule(for: window.bundleID)
            ?? appSources[window.pid]
            ?? settings.defaultSourceID
    }

    private func recordCurrentSource() {
        guard isRunning, let focused, let current = InputSources.currentID() else { return }
        // The toolset's own windows keep no memory.
        guard focused.pid != ProcessInfo.processInfo.processIdentifier else { return }
        if windowSources[focused] != current { log("record window=\(focused.windowID) = \(current)") }
        windowSources[focused] = current
        appSources[focused.pid] = current
    }

    private func log(_ message: String) {
        if logs { print(message); fflush(stdout) }
    }

    private func forget(pid: pid_t) {
        windowSources = windowSources.filter { $0.key.pid != pid }
        appSources[pid] = nil
    }
}
