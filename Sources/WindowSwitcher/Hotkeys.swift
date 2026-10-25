import AppKit
import Carbon.HIToolbox

/// The global keyboard input of the switcher.
///
/// Carbon hot keys catch Option-Tab, Option-Shift-Tab, and (during a switch) Option-Esc.
/// A listen-only event tap reports when the Option key goes up.
/// Both keep working while a password field has Secure Input on.
final class Hotkeys {
    enum Action: UInt32 {
        case next = 1
        case previous = 2
        case cancel = 3
    }

    var onAction: ((Action) -> Void)?
    var onOptionUp: (() -> Void)?

    /// True while the user holds the Option key.
    static var isOptionDown: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    fileprivate static let signature: OSType = 0x4F54_4142 // "OTAB"
    private var tabHotKeys: [EventHotKeyRef] = []
    private var cancelHotKey: EventHotKeyRef?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var handler: EventHandlerRef?

    /// Returns false when the event tap cannot start. This occurs when the app has no Accessibility permission.
    func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: flagsChanged,
            userInfo: refcon) else { return false }
        eventTap = tap
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, refcon, &handler)
        if let ref = register(UInt32(kVK_Tab), UInt32(optionKey), .next) { tabHotKeys.append(ref) }
        if let ref = register(UInt32(kVK_Tab), UInt32(optionKey | shiftKey), .previous) { tabHotKeys.append(ref) }
        return true
    }

    /// Releases the hot keys and the event tap, so other apps can use Option-Tab.
    func stop() {
        tabHotKeys.forEach { UnregisterEventHotKey($0) }
        tabHotKeys = []
        setCancelEnabled(false)
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventTap = nil
    }

    /// Option-Esc cancels a switch. The app registers it only during a switch, so other apps keep the key at other times.
    func setCancelEnabled(_ isEnabled: Bool) {
        if isEnabled, cancelHotKey == nil {
            cancelHotKey = register(UInt32(kVK_Escape), UInt32(optionKey), .cancel)
        } else if !isEnabled, let ref = cancelHotKey {
            UnregisterEventHotKey(ref)
            cancelHotKey = nil
        }
    }

    private func register(_ keyCode: UInt32, _ modifiers: UInt32, _ action: Action) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("Window Switcher: RegisterEventHotKey failed for \(action), status \(status)")
        }
        return ref
    }

    fileprivate func handleHotKey(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        onAction?(action)
    }

    fileprivate func handleFlags(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS can turn off an event tap. Turn it on again.
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        if type == .flagsChanged, !event.flags.contains(.maskAlternate) {
            onOptionUp?()
        }
    }
}

private func hotKeyPressed(_ handler: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == Hotkeys.signature else { return OSStatus(eventNotHandledErr) }
    Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue().handleHotKey(id.id)
    return noErr
}

private func flagsChanged(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue().handleFlags(type, event)
    }
    return Unmanaged.passUnretained(event)
}
