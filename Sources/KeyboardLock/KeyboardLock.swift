import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import SwiftUI
import ToolsetCore

/// Locks the keyboard for a short time, so the user can clean it.
/// Hold Command-Shift-L for 3 seconds to lock. Click the lock on the screen, and the keyboard unlocks after 3 seconds.
/// This feature replaces the separate app KeyboardCleanTool.
public final class KeyboardLock: ObservableObject, ToolsetFeature {
    public let id = "keyboard-lock"
    public let title = "Keyboard Lock"
    public let summary = "Hold ⌘⇧L for 3 seconds to lock the keyboard while you clean it."
    public let needsAccessibility = true

    static let holdTime = 3.0
    static let unlockTime = 3.0
    fileprivate static let signature: OSType = 0x5453_4B4C // "TSKL"

    private enum State {
        case idle
        case holding(since: Date)
        case locked
        case unlocking(since: Date)
    }

    @Published private(set) var isLocked = false
    private var state = State.idle
    private let blocker = KeyBlocker()
    private let overlay = LockOverlay()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0

    public init() {}

    public func start() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Keyboard Lock: RegisterEventHotKey failed, status \(status)") }
    }

    public func stop() {
        unlock()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    // MARK: Lock

    fileprivate func handleHotKey() {
        // The hot key can repeat while the user holds it. Only the first press starts the hold.
        guard case .idle = state else { return }
        state = .holding(since: Date())
        startTimer()
    }

    /// Locks at once, without the hold. The menu and the Settings pane use this.
    public func lockNow() {
        guard case .idle = state else { return }
        lock()
    }

    private func lock() {
        stopTimer()
        // A password field turns on Secure Input. Then macOS sends the keys past all event taps, so the lock cannot work.
        if IsSecureEventInputEnabled() {
            showRefusal("A password field is active, so the\nkeyboard cannot be locked now.")
            return
        }
        guard blocker.start() else {
            showRefusal("Toolset needs the Accessibility\npermission to lock the keyboard.")
            return
        }
        state = .locked
        isLocked = true
        overlay.showLock { [weak self] in self?.lockClicked() }
        // The user does not touch the keyboard, so macOS can think that the Mac is idle. Keep the display on.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Toolset Keyboard Lock" as CFString, &sleepAssertion)
    }

    private func lockClicked() {
        switch state {
        case .locked:
            state = .unlocking(since: Date())
            startTimer()
        case .unlocking:
            // A second click stops the countdown.
            stopTimer()
            state = .locked
            overlay.updateLock(progress: nil, caption: LockOverlay.lockedCaption)
        default:
            break
        }
    }

    private func unlock() {
        stopTimer()
        overlay.hideHold()
        guard isLocked else {
            state = .idle
            return
        }
        blocker.stop()
        overlay.hideLock()
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        sleepAssertion = 0
        state = .idle
        isLocked = false
    }

    private func showRefusal(_ caption: String) {
        state = .idle
        overlay.showHold(progress: nil, caption: caption)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, case .idle = self.state else { return }
            self.overlay.hideHold()
        }
    }

    // MARK: Timer

    /// One timer moves the progress ring. It runs only during the hold and the unlock countdown.
    private func startTimer() {
        stopTimer()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        switch state {
        case .holding(let since):
            guard Self.isShortcutDown else {
                stopTimer()
                overlay.hideHold()
                state = .idle
                return
            }
            let progress = Date().timeIntervalSince(since) / Self.holdTime
            if progress >= 1 {
                lock()
            } else {
                overlay.showHold(progress: progress, caption: "Hold ⌘⇧L to lock the keyboard")
            }
        case .unlocking(let since):
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= Self.unlockTime {
                unlock()
            } else {
                let seconds = Int((Self.unlockTime - elapsed).rounded(.up))
                overlay.updateLock(progress: elapsed / Self.unlockTime, caption: "Unlocking in \(seconds) s.\nClick the lock again to stay locked.")
            }
        default:
            stopTimer()
        }
    }

    /// True while the user holds Command, Shift, and L.
    private static var isShortcutDown: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskCommand) && flags.contains(.maskShift)
            && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_L))
    }

    // MARK: ToolsetFeature

    public func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Lock Keyboard Now", action: #selector(lockFromMenu), keyEquivalent: "")
        item.target = self
        let hint = NSMenuItem(title: "Or hold ⌘⇧L for 3 seconds", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        return [item, hint]
    }

    @objc private func lockFromMenu() { lockNow() }

    public func makeSettingsSections() -> AnyView {
        AnyView(KeyboardLockSettingsView(lock: self))
    }
}

private func hotKeyPressed(_ handler: EventHandlerCallRef?, _ event: EventRef?, _ refcon: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let refcon else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr, id.signature == KeyboardLock.signature else { return OSStatus(eventNotHandledErr) }
    Unmanaged<KeyboardLock>.fromOpaque(refcon).takeUnretainedValue().handleHotKey()
    return noErr
}
