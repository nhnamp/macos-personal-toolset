// Accessibility helpers: find the AXUIElement of a window, read its title, set its frame.

import AppKit
import ApplicationServices
import ToolsetCore

enum WindowAX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns the AXUIElements of the wanted windows of one app, keyed by window ID.
    /// Many apps list only the windows of the visible Space in `AXWindows`. For windows on
    /// other Spaces, we try the element IDs one by one with a remote token (same method as
    /// AltTab). A time limit of 0.2 s per app keeps this fast.
    static func elements(forWindows wanted: Set<UInt32>, pid: pid_t) -> [UInt32: AXUIElement] {
        var found: [UInt32: AXUIElement] = [:]
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        for window in AX.elements(app, kAXWindowsAttribute) {
            if let id = AX.windowId(window), wanted.contains(id) { found[id] = window }
        }
        guard found.count < wanted.count, let createWithRemoteToken = PrivateAPIs.createWithRemoteToken else { return found }

        // Token layout: pid (4 bytes), 0 (4 bytes), "coco" (4 bytes), element ID (8 bytes).
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(0.2)
        for elementID: UInt64 in 0..<2000 where found.count < wanted.count && Date() < deadline {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  let id = AX.windowId(element), wanted.contains(id), found[id] == nil,
                  AX.string(element, kAXRoleAttribute) == kAXWindowRole else { continue }
            found[id] = element
        }
        return found
    }

    /// Returns the AXUIElements of windows of several apps, keyed by window ID.
    static func elements(for windows: [LiveWindow]) -> [UInt32: AXUIElement] {
        var result: [UInt32: AXUIElement] = [:]
        for (pid, group) in Dictionary(grouping: windows, by: \.pid) {
            result.merge(elements(forWindows: Set(group.map(\.windowID)), pid: pid)) { first, _ in first }
        }
        return result
    }

    static func title(of element: AXUIElement) -> String {
        AX.string(element, kAXTitleAttribute) ?? ""
    }

    /// The real frame of the window (top-left global coordinates).
    /// With Stage Manager on, `CGWindowList` gives the small frame of the window in the side strip.
    /// Accessibility gives the frame that the window has when it is in the center.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = AX.copyValue(element, kAXPositionAttribute), let size = AX.copyValue(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Sets the window frame (top-left global coordinates).
    /// The position is set before and after the size, because apps clamp the size to the
    /// display that contains the window at that moment.
    @discardableResult
    static func setFrame(_ element: AXUIElement, _ frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        let second = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let third = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        return first == .success || second == .success || third == .success
    }
}
