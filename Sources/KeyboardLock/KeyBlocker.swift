import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem

/// Removes all keyboard events while the keyboard is locked.
///
/// An active event tap removes key presses, modifier changes, and the media keys (volume, brightness, play).
/// The tap exists only while the keyboard is locked.
///
/// The tap cannot stop the power / Touch ID key, and it cannot stop the Caps Lock light.
/// So the blocker saves the Caps Lock state and the input source, and puts them back at unlock.
final class KeyBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var capsLock: Bool?
    private var inputSource: TISInputSource?

    /// NX_SYSDEFINED: the event type of the media keys. Subtype 8 is a media key.
    private static let systemDefinedType: UInt32 = 14
    private static let mediaKeySubtype: Int16 = 8

    /// Returns false when macOS refuses the tap (no Accessibility permission).
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [UInt32] = [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, Self.systemDefinedType]
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: types.reduce(CGEventMask(0)) { $0 | (1 << $1) },
            callback: blockCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        capsLock = Self.capsLockState()
        inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return true
    }

    func stop() {
        guard let tap else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        // A press of Caps Lock or fn during the lock can change these two values.
        if let capsLock, Self.capsLockState() != capsLock { Self.setCapsLockState(capsLock) }
        if let inputSource { TISSelectInputSource(inputSource) }
        capsLock = nil
        inputSource = nil
    }

    /// Returns nil to remove the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS can turn off an event tap. Turn it on again.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        case .keyDown, .keyUp, .flagsChanged:
            return nil
        default:
            // Other system-defined events (for example the extra mouse buttons) pass.
            guard type.rawValue == Self.systemDefinedType, NSEvent(cgEvent: event)?.subtype.rawValue == Self.mediaKeySubtype else { return event }
            return nil
        }
    }

    // MARK: Caps Lock

    private static func capsLockState() -> Bool? {
        withHIDSystem { connect in
            var state = false
            return IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS ? state : nil
        }
    }

    private static func setCapsLockState(_ state: Bool) {
        _ = withHIDSystem { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), state) }
    }

    private static func withHIDSystem<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }
}

private func blockCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let blocker = Unmanaged<KeyBlocker>.fromOpaque(refcon).takeUnretainedValue()
    return blocker.handle(type, event).map { Unmanaged.passUnretained($0) }
}
