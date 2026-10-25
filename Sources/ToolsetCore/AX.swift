import AppKit
import ApplicationServices

/// Small helpers for the Accessibility API.
public enum AX {
    public static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyValue(element, attribute) as? String
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copyValue(element, attribute) as? Bool
    }

    public static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyValue(element, attribute) as? [AXUIElement] ?? []
    }

    /// A normal document or app window. Panels, sheets, and pop-up menus are not standard windows.
    /// macOS reports a minimized window with the subrole `AXDialog`, so a minimized window is also accepted.
    public static func isStandardWindow(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole || bool(element, kAXMinimizedAttribute) == true
    }

    /// False when the app closed the window or replaced its Accessibility element.
    public static func isAlive(_ element: AXUIElement) -> Bool {
        copyValue(element, kAXRoleAttribute) != nil
    }

    public static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// The window server ID of a window. It is nil when the private function is missing.
    public static func windowId(_ element: AXUIElement) -> CGWindowID? {
        guard let getWindow = PrivateAPIs.getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Asks for the permission once, then calls `onTrusted` as soon as the user turns it on.
    /// Returns the timer that checks each second, or nil when the permission is already there.
    @discardableResult
    public static func whenTrusted(_ onTrusted: @escaping () -> Void) -> Timer? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            onTrusted()
            return nil
        }
        return Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            onTrusted()
        }
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
