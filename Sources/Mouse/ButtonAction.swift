import AppKit
import Carbon.HIToolbox

/// The extra buttons of a mouse. The values are the button numbers in the mouse events.
public enum MouseButton: Int64, CaseIterable, Identifiable {
    case middle = 2
    case back = 3
    case forward = 4

    public var id: Int64 { rawValue }

    public var title: String {
        switch self {
        case .middle: "Middle button"
        case .back: "Back button"
        case .forward: "Forward button"
        }
    }

    /// The action for a hold when the user did not choose one. These match the examples of the user.
    var defaultHoldAction: ButtonAction {
        switch self {
        case .middle: .lookUp
        case .back: .missionControl
        case .forward: .none
        }
    }
}

/// A macOS action that a held mouse button can start. Each action is the same as a trackpad gesture.
public enum ButtonAction: String, CaseIterable, Identifiable {
    case none
    case missionControl
    case appExpose
    case showDesktop
    case apps
    case previousSpace
    case nextSpace
    case lookUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "Nothing (normal button)"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .showDesktop: "Show Desktop"
        case .apps: "Apps"
        case .previousSpace: "Previous Space"
        case .nextSpace: "Next Space"
        case .lookUp: "Look Up"
        }
    }

    /// Starts the action. Call it on the main thread.
    func perform() {
        switch self {
        case .none: break
        case .missionControl: Dock.send("com.apple.expose.awake")
        case .appExpose: Dock.send("com.apple.expose.front.awake")
        case .showDesktop: Dock.send("com.apple.showdesktop.awake")
        case .apps: Dock.send("com.apple.launchpad.toggle")
        case .previousSpace: Keys.press(kVK_LeftArrow, [.maskControl, .maskSecondaryFn, .maskNumericPad], holding: kVK_Control)
        case .nextSpace: Keys.press(kVK_RightArrow, [.maskControl, .maskSecondaryFn, .maskNumericPad], holding: kVK_Control)
        // ⌃⌘D is the system shortcut for Look Up of the word under the pointer.
        case .lookUp: Keys.press(kVK_ANSI_D, [.maskControl, .maskCommand], holding: nil)
        }
    }
}

/// The Dock opens Mission Control, App Exposé, Show Desktop, and Apps when it gets these private notifications.
private enum Dock {
    private typealias SendFn = @convention(c) (CFString, Int32) -> Void
    private static let sendFn: SendFn? = {
        // The function is in HIServices. Open the framework, because a plain dlsym finds it only after something loads it.
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let pointer = dlsym(handle, "CoreDockSendNotification") else { return nil }
        return unsafeBitCast(pointer, to: SendFn.self)
    }()

    static func send(_ name: String) {
        guard let sendFn else {
            NSLog("Mouse: CoreDockSendNotification is missing")
            return
        }
        sendFn(name as CFString, 0)
    }
}

/// Posts key presses as a keyboard sends them.
private enum Keys {
    /// `holding` is a modifier key that goes down before the key and up after it.
    /// The Space shortcuts (⌃← and ⌃→) work only with this modifier key event, and with the fn and keypad flags of an arrow key.
    static func press(_ key: Int, _ flags: CGEventFlags, holding modifier: Int?) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let modifier { post(source, modifier, down: true, flags.intersection(.maskControl)) }
        post(source, key, down: true, flags)
        post(source, key, down: false, flags)
        if let modifier { post(source, modifier, down: false, []) }
    }

    private static func post(_ source: CGEventSource?, _ key: Int, down: Bool, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
