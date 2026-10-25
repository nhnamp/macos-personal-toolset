// Adds and removes Spaces through the Mission Control interface of the Dock.
// macOS has no API for this without System Integrity Protection changes. The Dock exposes
// its "Add Desktop" button and the "Remove Desktop" action to Accessibility. On macOS 27,
// the Mission Control group gives no children from the top down, so we find the Spaces
// bar with a hit test at the top of each display.

import AppKit
import ApplicationServices
import ToolsetCore

enum MissionControlError: Error, CustomStringConvertible {
    case notTrusted
    case dockNotRunning
    case spacesBarNotFound(CGDirectDisplayID)
    case buttonCountMismatch(expected: Int, found: Int)
    case actionFailed(String)

    var description: String {
        switch self {
        case .notTrusted: return "Accessibility permission is missing"
        case .dockNotRunning: return "the Dock is not running"
        case .spacesBarNotFound(let id): return "Mission Control Spaces bar not found on display \(id)"
        case .buttonCountMismatch(let expected, let found): return "Mission Control shows \(found) Spaces, expected \(expected)"
        case .actionFailed(let name): return "Mission Control action \(name) failed"
        }
    }
}

enum MissionControl {
    private typealias SendNotificationFn = @convention(c) (CFString, Int32) -> Void
    private static let sendDockNotification: SendNotificationFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(pointer, to: SendNotificationFn.self)
    }()

    static var isAvailable: Bool { sendDockNotification != nil }

    /// Opens Mission Control, runs `body`, and closes Mission Control again.
    static func withMissionControl(_ body: () throws -> Void) throws {
        guard WindowAX.isTrusted else { throw MissionControlError.notTrusted }
        guard let dock = dockElement() else { throw MissionControlError.dockNotRunning }
        if !isOpen(dock) { toggle() }
        defer {
            usleep(300_000)
            if isOpen(dock) { toggle() }
            usleep(400_000) // Let the close animation end before windows move.
        }
        try body()
    }

    /// Adds Spaces at the end of the display's list. Call inside `withMissionControl`.
    static func addSpaces(_ count: Int, toDisplay displayID: CGDirectDisplayID) throws {
        for _ in 0..<count {
            let bar = try spacesBar(onDisplay: displayID)
            guard let addButton = children(bar).first(where: { identifier($0) == "mc.spaces.add" }),
                  AXUIElementPerformAction(addButton, "AXPress" as CFString) == .success
            else { throw MissionControlError.actionFailed("Add Desktop") }
            usleep(500_000)
        }
    }

    /// Removes the Space at a position in the display's Mission Control list.
    /// `expectedCount` is the number of Spaces (user and full-screen) that SkyLight reports.
    /// Call inside `withMissionControl`.
    static func removeSpace(at index: Int, expectedCount: Int, fromDisplay displayID: CGDirectDisplayID) throws {
        let bar = try spacesBar(onDisplay: displayID)
        guard let list = children(bar).first(where: { identifier($0) == "mc.spaces.list" }) else {
            throw MissionControlError.spacesBarNotFound(displayID)
        }
        let buttons = children(list)
        guard buttons.count == expectedCount else {
            throw MissionControlError.buttonCountMismatch(expected: expectedCount, found: buttons.count)
        }
        guard AXUIElementPerformAction(buttons[index], "AXRemoveDesktop" as CFString) == .success else {
            throw MissionControlError.actionFailed("Remove Desktop")
        }
        usleep(500_000)
    }

    // MARK: Helpers

    private static func toggle() {
        sendDockNotification?("com.apple.expose.awake" as CFString, 0)
    }

    private static func dockElement() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        return element
    }

    private static func isOpen(_ dock: AXUIElement) -> Bool {
        children(dock).contains { identifier($0) == "mc" }
    }

    /// Finds the Spaces bar of a display: hit test the top center of the display, then walk up.
    private static func spacesBar(onDisplay displayID: CGDirectDisplayID) throws -> AXUIElement {
        let bounds = Displays.bounds(of: displayID)
        let systemWide = AXUIElementCreateSystemWide()
        for _ in 0..<40 {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(bounds.midX), Float(bounds.minY + 10), &hit) == .success,
               let hit, let bar = ancestor(of: hit, withIdentifier: "mc.spaces"),
               let display = ancestor(of: bar, withIdentifier: "mc.display"),
               (AX.copyValue(display, "AXDisplayID") as? NSNumber)?.uint32Value == displayID {
                return bar
            }
            usleep(50_000)
        }
        throw MissionControlError.spacesBarNotFound(displayID)
    }

    private static func ancestor(of element: AXUIElement, withIdentifier wanted: String) -> AXUIElement? {
        var current: AXUIElement? = element
        while let node = current {
            if identifier(node) == wanted { return node }
            guard let parent = AX.element(node, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        AX.elements(element, kAXChildrenAttribute)
    }

    private static func identifier(_ element: AXUIElement) -> String {
        AX.string(element, kAXIdentifierAttribute) ?? ""
    }
}
