import AppKit
import ApplicationServices

/// The focused window of the frontmost app.
public struct FocusedWindow: Hashable {
    public let pid: pid_t
    /// The window server ID. It is 0 when the app has no focused window or the private function is missing.
    public let windowID: CGWindowID
    public let bundleID: String?
}

/// Follows the focused window: across app switches, and between the windows of one app.
/// The toolset runs one tracker, and each feature subscribes to it.
/// It observes only the frontmost app, and moves to the new app at each app switch.
/// Each running feature calls `start()` once and `stop()` once. The tracker runs while one feature or more needs it.
public final class FocusTracker {
    public private(set) var current: FocusedWindow?
    private var handlers: [(FocusedWindow) -> Void] = []
    private var users = 0
    private var observer: AXObserver?
    private var activationToken: NSObjectProtocol?

    public init() {}

    public func subscribe(_ handler: @escaping (FocusedWindow) -> Void) {
        handlers.append(handler)
    }

    public func start() {
        users += 1
        guard users == 1 else { return }
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.follow(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication { follow(app) }
    }

    public func stop() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        stopObserver()
        current = nil
    }

    private func follow(_ app: NSRunningApplication) {
        stopObserver()
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        // The activation comes before any focus notification of the new app, so read its focused window now.
        publish(window: AX.element(appElement, kAXFocusedWindowAttribute), pid: pid)

        var newObserver: AXObserver?
        guard AXObserverCreate(pid, focusedWindowChanged, &newObserver) == .success, let newObserver else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(newObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver

        // The app can move its focus between the read above and the start of the observation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.publish(window: AX.element(appElement, kAXFocusedWindowAttribute), pid: pid)
        }
    }

    fileprivate func publish(window: AXUIElement?, pid: pid_t) {
        let id = window.flatMap(AX.windowId) ?? 0
        let focused = FocusedWindow(pid: pid, windowID: id, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        guard focused != current else { return }
        current = focused
        for handler in handlers { handler(focused) }
    }

    private func stopObserver() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }
}

private func focusedWindowChanged(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue().publish(window: element, pid: pid)
}
