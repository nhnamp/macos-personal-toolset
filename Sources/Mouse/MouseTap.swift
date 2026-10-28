import AppKit

/// Changes the scroll events of a mouse wheel, and starts an action when the user holds an extra mouse button.
/// The events of a trackpad and a Magic Mouse do not change.
///
/// Scrolling: a wheel sends line events (`scrollWheelEventIsContinuous` is 0). A trackpad sends continuous pixel events.
/// An active event tap catches the line events:
/// - Invert: the tap changes the sign of the deltas.
/// - Smooth: the tap removes the line event. A timer then posts small pixel events with scroll phases,
///   so the content glides to its new position.
///
/// Buttons: when a button has a hold action, the tap keeps back its press.
/// - Release before `holdTime`: the tap sends the press and the release, so the app gets a normal click.
/// - Movement of more than `dragLimit` before `holdTime`: the tap sends the press, and the drag continues as normal.
/// - Still held at `holdTime`: the action starts. The tap removes the release.
///
/// The tap and the timers run on their own thread. If the main thread is busy, macOS does not turn off the tap.
final class MouseTap {
    struct Options: Equatable {
        var smooth: Bool
        var invert: Bool
        /// Only the buttons that have an action. Other buttons pass unchanged.
        var holdActions: [Int64: ButtonAction]

        var needsTap: Bool { smooth || invert || !holdActions.isEmpty }
    }

    /// The distance of one wheel step, in pixels. Mac Mouse Fix used 40 on this Mac. WebKit also scrolls 40 pixels for one line.
    static let pixelsPerLine = 40.0
    /// The time constant of the glide. After 0.1 s, 86 % of the distance is done.
    static let glideTime = 0.05
    static let frameInterval = 1.0 / 120
    /// The tap ignores the events that carry this value. Toolset posts them itself. ("TSSC")
    static let marker: Int64 = 0x5453_5343
    /// A press that is longer than this is a hold.
    static let holdTime = 0.3
    /// A movement of more points than this, before `holdTime`, makes the press a normal drag.
    static let dragLimit = 10.0

    private let lock = NSLock()
    private var currentOptions = Options(smooth: false, invert: false, holdActions: [:])
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?

    // The glide state. Only the tap thread uses these values.
    private var remaining = 0.0
    private var subPixel = 0.0
    private var lastFrame = 0.0
    private var hasBegun = false
    private var timer: CFRunLoopTimer?

    /// A button press that the tap keeps back. Only the tap thread uses these values.
    private struct Press {
        let down: CGEvent
        let action: ButtonAction
        var timer: CFRunLoopTimer?
        var didStartAction = false
    }
    private var presses: [Int64: Press] = [:]

    var options: Options {
        get { lock.withLock { currentOptions } }
        set { lock.withLock { currentOptions = newValue } }
    }

    var isRunning: Bool { runLoop != nil }

    /// Starts the thread and the tap. Returns false when macOS refuses the tap (no Accessibility permission).
    func start() -> Bool {
        guard runLoop == nil else { return true }
        let ready = DispatchSemaphore(value: 0)
        var created = false
        let thread = Thread { [weak self] in
            guard let self, let tap = self.makeTap() else {
                ready.signal()
                return
            }
            self.tap = tap
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            created = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Toolset scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created
    }

    func stop() {
        guard let runLoop else { return }
        self.runLoop = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            stopGlide()
            presses.values.forEach { if let timer = $0.timer { CFRunLoopTimerInvalidate(timer) } }
            presses = [:]
            if let tap { CFMachPortInvalidate(tap) }
            tap = nil
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func makeTap() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: [CGEventType.scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
                .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) },
            callback: mouseCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Returns nil to remove the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent, _ proxy: CGEventTapProxy) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS can turn off an event tap. Turn it on again.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        case .scrollWheel:
            return handleScroll(event)
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            return handleButton(type, event, proxy)
        default:
            return event
        }
    }

    private func handleScroll(_ event: CGEvent) -> CGEvent? {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return event }

        let options = options
        let lines = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        // Only plain vertical scrolling glides. With a modifier key, apps zoom or scroll sideways,
        // and a horizontal glide with scroll phases can start the back/forward swipe of a browser.
        if options.smooth, lines != 0, event.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0,
           event.flags.intersection(modifiers).isEmpty {
            // macOS increases the line count when the wheel turns fast. The scroll speed in System Settings changes this increase.
            glide(by: Double(options.invert ? -lines : lines) * Self.pixelsPerLine)
            return nil
        }
        if options.invert { Self.invert(event) }
        return event
    }

    private static func invert(_ event: CGEvent) {
        let integerFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                                             .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        let doubleFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        // Read all values first. A change of one delta field can change the other fields.
        let integers = integerFields.map { event.getIntegerValueField($0) }
        let doubles = doubleFields.map { event.getDoubleValueField($0) }
        for (field, value) in zip(integerFields, integers) { event.setIntegerValueField(field, value: -value) }
        for (field, value) in zip(doubleFields, doubles) { event.setDoubleValueField(field, value: -value) }
    }

    // MARK: Buttons

    private func handleButton(_ type: CGEventType, _ event: CGEvent, _ proxy: CGEventTapProxy) -> CGEvent? {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch type {
        case .otherMouseDown:
            guard let action = options.holdActions[button], presses[button] == nil, let down = event.copy() else { return event }
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.holdTime, 0, 0, 0) { [weak self] _ in
                self?.holdTimeReached(button)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            presses[button] = Press(down: down, action: action, timer: timer)
            return nil
        case .otherMouseDragged:
            guard let press = presses[button] else { return event }
            if press.didStartAction { return nil }
            let start = press.down.location, now = event.location
            guard hypot(now.x - start.x, now.y - start.y) > Self.dragLimit else { return nil }
            // A drag, not a hold. Send the press that the tap kept back, then let the drag pass.
            endPress(button)
            press.down.tapPostEvent(proxy)
            return event
        default: // .otherMouseUp
            guard let press = presses[button] else { return event }
            endPress(button)
            if press.didStartAction { return nil }
            // A short click. The app gets the press now, and then this release.
            press.down.tapPostEvent(proxy)
            return event
        }
    }

    private func holdTimeReached(_ button: Int64) {
        guard var press = presses[button] else { return }
        press.didStartAction = true
        press.timer = nil
        presses[button] = press
        let action = press.action
        DispatchQueue.main.async { action.perform() }
    }

    private func endPress(_ button: Int64) {
        if let timer = presses[button]?.timer { CFRunLoopTimerInvalidate(timer) }
        presses[button] = nil
    }

    // MARK: Glide

    private func glide(by distance: Double) {
        // A step in the other direction stops the current glide at once.
        if remaining * distance < 0 { remaining = 0 }
        remaining += distance
        guard timer == nil else { return }
        lastFrame = CFAbsoluteTimeGetCurrent()
        let timer = CFRunLoopTimerCreateWithHandler(nil, lastFrame, Self.frameInterval, 0, 0) { [weak self] _ in self?.frame() }
        self.timer = timer
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        frame()
    }

    private func frame() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(now - lastFrame, Self.frameInterval)
        lastFrame = now
        var step = remaining * (1 - exp(-elapsed / Self.glideTime))
        if abs(remaining) < 1 { step = remaining }
        remaining -= step
        subPixel += step
        let pixels = subPixel.rounded(.towardZero)
        subPixel -= pixels
        if pixels != 0 {
            post(pixels: Int32(pixels), phase: hasBegun ? .changed : .began)
            hasBegun = true
        }
        if abs(remaining) < 0.5 { stopGlide() }
    }

    private func stopGlide() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
        if hasBegun { post(pixels: 0, phase: .ended) }
        hasBegun = false
        remaining = 0
        subPixel = 0
    }

    /// The values of `scrollWheelEventScrollPhase`, as a trackpad sends them.
    private enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    private func post(pixels: Int32, phase: Phase) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}

private func mouseCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type, event, proxy).map { Unmanaged.passUnretained($0) }
}
