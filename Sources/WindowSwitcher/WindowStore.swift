import AppKit
import ToolsetCore
import ApplicationServices

/// One line in the switcher list.
struct SwitcherWindow {
    let element: AXUIElement
    /// The window server ID. It is nil in the public-only mode.
    let windowId: CGWindowID?
    let title: String
    let isMinimized: Bool
}

/// Finds the windows of one app on all Spaces.
///
/// The public Accessibility API returns only the windows on the current Space and the minimized windows.
/// For the windows on other Spaces, the store searches with the private remote-token API on a background queue.
/// It keeps each window that it sees or finds in a cache, so the search for one window runs only once.
final class WindowStore {
    static let maxWindows = 20
    /// Element IDs grow while an app runs. A time limit, not an ID limit, ends the search.
    static let searchTimeLimit: TimeInterval = 0.5

    /// Windows that the public API returned or the private search found, per app.
    /// A window stays here after the user leaves its Space, until the window closes.
    private var knownWindows: [pid_t: [CGWindowID: AXUIElement]] = [:]
    /// Window IDs that the last search did not find, per app.
    /// Some window server windows are helper windows that never resolve. A new search starts only when
    /// the set of unresolved IDs changes, so these helper windows do not start a search on each key press.
    private var unresolvedIds: [pid_t: Set<CGWindowID>] = [:]
    private var searchesInProgress: Set<pid_t> = []
    /// Window IDs in focus order, most recent first, per app.
    private var recentIds: [pid_t: [CGWindowID]] = [:]
    private let searchQueue = DispatchQueue(label: "WindowSwitcher.windowSearch", qos: .userInitiated)

    /// Returns the windows of the app: the focused window first, then the other windows in focus order.
    func windows(of app: NSRunningApplication) -> [SwitcherWindow] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        let publicWindows = AX.elements(appElement, kAXWindowsAttribute).filter(AX.isStandardWindow)

        guard PrivateAPIs.getWindow != nil else {
            // Public-only mode. The Accessibility API gives the windows front to back, which is the focus order.
            return makeList(publicWindows.map { ($0, nil) }, appName: app.localizedName)
        }

        var byId: [CGWindowID: AXUIElement] = [:]
        var publicOrder: [CGWindowID] = []
        for element in publicWindows {
            guard let id = AX.windowId(element) else { continue }
            byId[id] = element
            publicOrder.append(id)
        }
        let serverOrder = Self.serverWindowIds(pid: pid)
        for (id, element) in knownWindows[pid] ?? [:] where byId[id] == nil {
            // Remove windows that closed, and elements that the app replaced.
            guard serverOrder.contains(id), AX.isAlive(element) else {
                knownWindows[pid]?[id] = nil
                continue
            }
            byId[id] = element
        }
        knownWindows[pid] = byId

        let focusedId = AX.element(appElement, kAXFocusedWindowAttribute).flatMap(AX.windowId)
        let recent = recentIds[pid] ?? []
        func rank(_ id: CGWindowID) -> [Int] {
            [id == focusedId ? 0 : 1,
             recent.firstIndex(of: id) ?? Int.max,
             publicOrder.firstIndex(of: id) ?? Int.max,
             serverOrder.firstIndex(of: id) ?? Int.max]
        }
        let ordered = byId.keys.sorted { rank($0).lexicographicallyPrecedes(rank($1)) }
        return makeList(ordered.map { (byId[$0]!, $0) }, appName: app.localizedName)
    }

    /// Records that a window got the focus.
    func noteFocused(pid: pid_t, windowId: CGWindowID) {
        var ids = recentIds[pid] ?? []
        ids.removeAll { $0 == windowId }
        ids.insert(windowId, at: 0)
        recentIds[pid] = Array(ids.prefix(50))
    }

    /// Starts a background search for the app windows that the public API does not return.
    /// Calls `completion` on the main thread when the search ends.
    /// Returns false when no search is necessary or possible.
    @discardableResult
    func searchIfNeeded(for app: NSRunningApplication, completion: @escaping () -> Void) -> Bool {
        guard PrivateAPIs.canFindWindowsOnAllSpaces else { return false }
        let pid = app.processIdentifier
        guard !searchesInProgress.contains(pid) else { return false }

        var knownIds = Set((knownWindows[pid] ?? [:]).keys)
        for element in AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute) {
            guard let id = AX.windowId(element) else { continue }
            knownIds.insert(id)
            // Keep the windows of the current Space, so they stay in the list after the user leaves this Space.
            if AX.isStandardWindow(element) { knownWindows[pid, default: [:]][id] = element }
        }
        let missing = Set(Self.serverWindowIds(pid: pid)).subtracting(knownIds)
        guard !missing.isEmpty, missing != unresolvedIds[pid] else { return false }

        searchesInProgress.insert(pid)
        searchQueue.async {
            let found = Self.search(pid: pid, wanted: missing)
            DispatchQueue.main.async {
                self.searchesInProgress.remove(pid)
                self.knownWindows[pid, default: [:]].merge(found) { _, new in new }
                self.unresolvedIds[pid] = missing.subtracting(found.keys)
                completion()
            }
        }
        return true
    }

    /// Window server IDs of the normal windows of an app on all Spaces, front to back.
    /// The filter skips small and transparent helper windows.
    /// This call does not need Screen Recording, because it does not read window names.
    static func serverWindowIds(pid: pid_t) -> [CGWindowID] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 0) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 100, (bounds["Height"] ?? 0) > 100 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// Tries Accessibility element IDs one by one until it finds all wanted windows or the time is up.
    private static func search(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        guard let createWithRemoteToken = PrivateAPIs.createWithRemoteToken else { return [:] }
        var found: [CGWindowID: AXUIElement] = [:]
        // Token layout: pid (4 bytes), 0 (4 bytes), "coco" (4 bytes), element ID (8 bytes).
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f_636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(searchTimeLimit)
        var elementId: UInt64 = 0
        while found.count < wanted.count, Date() < deadline {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })
            elementId += 1
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  let id = AX.windowId(element), wanted.contains(id), found[id] == nil,
                  AX.isStandardWindow(element) else { continue }
            found[id] = element
        }
        return found
    }

    private func makeList(_ items: [(AXUIElement, CGWindowID?)], appName: String?) -> [SwitcherWindow] {
        items.prefix(Self.maxWindows).enumerated().map { index, item in
            let title = AX.string(item.0, kAXTitleAttribute) ?? ""
            return SwitcherWindow(
                element: item.0,
                windowId: item.1,
                title: title.isEmpty ? "\(appName ?? "Window") — window \(index + 1)" : title,
                isMinimized: AX.bool(item.0, kAXMinimizedAttribute) ?? false)
        }
    }
}
