import AppKit

/// Changes the scroll events of a mouse wheel. The events of a trackpad and a Magic Mouse do not change.
///
/// A wheel sends line events (`scrollWheelEventIsContinuous` is 0). A trackpad sends continuous pixel events.
/// An active event tap catches the line events:
/// - Invert: the tap changes the sign of the deltas.
/// - Smooth: the tap removes the line event. A timer then posts small pixel events with scroll phases,
///   so the content glides to its new position.
///
/// The tap and the timer run on their own thread. If the main thread is busy, macOS does not turn off the tap.
final class ScrollTap {
    struct Options: Equatable {
        var smooth: Bool
        var invert: Bool
    }

    /// The distance of one wheel step, in pixels. Mac Mouse Fix used 40 on this Mac. WebKit also scrolls 40 pixels for one line.
    static let pixelsPerLine = 40.0
    /// The time constant of the glide. After 0.1 s, 86 % of the distance is done.
    static let glideTime = 0.05
    static let frameInterval = 1.0 / 120
    /// The tap ignores the events that carry this value. Toolset posts them itself. ("TSSC")
    static let marker: Int64 = 0x5453_5343

    private let lock = NSLock()
    private var currentOptions = Options(smooth: false, invert: false)
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?

    // The glide state. Only the tap thread uses these values.
    private var remaining = 0.0
    private var subPixel = 0.0
    private var lastFrame = 0.0
    private var hasBegun = false
    private var timer: CFRunLoopTimer?

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
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: scrollCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Returns nil to remove the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS can turn off an event tap. Turn it on again.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return event
        }
        guard type == .scrollWheel,
              event.getIntegerValueField(.eventSourceUserData) != Self.marker,
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

private func scrollCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type, event).map { Unmanaged.passUnretained($0) }
}
