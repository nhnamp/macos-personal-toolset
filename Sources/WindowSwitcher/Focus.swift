import AppKit
import ToolsetCore
import ApplicationServices

/// Brings a window to the front and gives it the keyboard focus.
enum Focus {
    /// `kCPSUserGenerated`: the window server treats the switch as a user action.
    private static let userGenerated: UInt32 = 0x200

    static func focus(_ window: SwitcherWindow, of app: NSRunningApplication) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let id = window.windowId, PrivateAPIs.canFocusAcrossSpaces,
           let getProcessForPID = PrivateAPIs.getProcessForPID,
           let setFrontProcess = PrivateAPIs.setFrontProcess {
            // This also moves to the Space of the window.
            var psn = ProcessSerialNumber()
            _ = getProcessForPID(app.processIdentifier, &psn)
            _ = setFrontProcess(&psn, id, userGenerated)
            makeKeyWindow(&psn, id)
        } else {
            app.activate()
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Sends a synthetic mouse down and mouse up to the window, far outside its content, so the window becomes key.
    /// The event record layout comes from yabai (MIT license): `window_manager_make_key_window` in src/window_manager.c.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowId: CGWindowID) {
        guard let postEventRecord = PrivateAPIs.postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowId) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01 // mouse down
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02 // mouse up
        _ = postEventRecord(&psn, &bytes)
    }
}
