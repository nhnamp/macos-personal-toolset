import AppKit
import CoreVideo

/// Moves the content after a wheel step: on each refresh of the display under the pointer, it posts one pixel scroll event.
///
/// - The speed falls off exponentially with the time constant `timeConstant`. New steps add to the remaining distance.
/// - Apps read only whole pixels (`scrollingDeltaY` is the integer point delta). A slow end would move 1 pixel
///   only on some frames, which looks jerky. So the speed never falls below `minimumSpeed`: the end moves at least
///   1 pixel on each frame of a 120 Hz display.
/// - The display link runs only during a glide. Its frames come at the refresh times of the display, so each frame
///   on the screen gets one step.
/// - A display link can stop without a call from Toolset. Then no frame comes, and the glide stays active.
///   So `add` checks the time of the last frame. After `stallTime` without a frame, it drops the glide,
///   makes a new display link, and returns false. The caller then sends the wheel event unchanged.
///
/// `add` and `cancel` run on the tap thread. The frames run on the display link thread. A lock protects the state.
final class Glide {
    /// The values of `scrollWheelEventScrollPhase`, as a trackpad sends them.
    enum Phase: Int64 {
        case began = 1
        case changed = 2
        case ended = 4
    }

    /// Pixels per second.
    static let minimumSpeed = 120.0
    /// Seconds without a frame, during a glide, after which the display link counts as stopped.
    static let stallTime = 0.2

    private let lock = NSLock()
    private var remaining = 0.0
    private var subPixel = 0.0
    private var lastFrame: Double?
    /// The time (`systemUptime`) of the start of the glide or of its last frame.
    private var lastProgress = 0.0
    private var hasBegun = false
    private var isActive = false
    private var currentTimeConstant = 0.1

    private var link: CVDisplayLink?
    /// All starts and stops of the display link go through this queue, in order.
    private let control = DispatchQueue(label: "Toolset glide control")
    private let post: (Int32, Phase) -> Void

    /// `post` sends one scroll event. The tap posts a real event. A test can record the steps.
    init(post: @escaping (Int32, Phase) -> Void) {
        self.post = post
    }

    /// Seconds. A longer time gives a longer, softer glide.
    var timeConstant: Double {
        get { lock.withLock { currentTimeConstant } }
        set { lock.withLock { currentTimeConstant = newValue } }
    }

    /// Returns false when the display link gives no frames. Then the glide does not take the distance.
    func add(_ distance: Double) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        var stalledAfterBegin = false
        let result: (needsStart: Bool, stalled: Bool) = lock.withLock {
            if isActive && now - lastProgress > Self.stallTime {
                // Drop the distance of the glide. A late start would make a large jump.
                stalledAfterBegin = hasBegun
                reset()
                return (false, true)
            }
            // A step in the other direction stops the current glide at once.
            if remaining * distance < 0 { remaining = 0 }
            remaining += distance
            if !isActive { lastProgress = now }
            defer { isActive = true }
            return (!isActive, false)
        }
        if result.stalled {
            if stalledAfterBegin { post(0, .ended) }
            control.async { self.discardLink() }
            return false
        }
        if result.needsStart { control.async { self.startLink() } }
        return true
    }

    /// Stops the glide now, for example when the tap stops.
    func cancel() {
        let wasBegun: Bool = lock.withLock {
            defer { reset() }
            return hasBegun
        }
        if wasBegun { post(0, .ended) }
        control.async { self.stopLinkIfIdle() }
    }

    /// One display refresh. `time` is the time of the frame on the screen, in seconds.
    func frame(at time: Double, refreshPeriod: Double) {
        var events: [(Int32, Phase)] = []
        let finished: Bool = lock.withLock {
            guard isActive else { return true }
            lastProgress = ProcessInfo.processInfo.systemUptime
            let elapsed = lastFrame.map { min(max(time - $0, 0.001), 0.05) } ?? refreshPeriod
            lastFrame = time
            var step = remaining * (1 - exp(-elapsed / currentTimeConstant))
            let minimumStep = Self.minimumSpeed * elapsed
            if abs(step) < minimumStep { step = remaining < 0 ? max(remaining, -minimumStep) : min(remaining, minimumStep) }
            remaining -= step
            subPixel += step
            let pixels = subPixel.rounded()
            subPixel -= pixels
            if pixels != 0 {
                events.append((Int32(pixels), hasBegun ? .changed : .began))
                hasBegun = true
            }
            guard remaining == 0 else { return false }
            if hasBegun { events.append((0, .ended)) }
            reset()
            return true
        }
        events.forEach { post($0.0, $0.1) }
        if finished { control.async { self.stopLinkIfIdle() } }
    }

    /// Call with the lock held.
    private func reset() {
        remaining = 0
        subPixel = 0
        lastFrame = nil
        hasBegun = false
        isActive = false
    }

    // MARK: Display link

    private func startLink() {
        if link == nil {
            var created: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&created)
            guard let created else { return }
            CVDisplayLinkSetOutputHandler(created) { [weak self] link, _, outputTime, _, _ in
                let seconds = Double(outputTime.pointee.hostTime) * Self.secondsPerHostTick
                let period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
                self?.frame(at: seconds, refreshPeriod: period > 0 ? period : 1.0 / 60)
                return kCVReturnSuccess
            }
            link = created
        }
        guard let link, !CVDisplayLinkIsRunning(link) else { return }
        CVDisplayLinkSetCurrentCGDisplay(link, Self.displayUnderPointer())
        // If the start fails, no frame comes, and the next `add` finds the stall.
        if CVDisplayLinkStart(link) != kCVReturnSuccess { discardLink() }
    }

    /// The next start makes a new display link.
    private func discardLink() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
    }

    private func stopLinkIfIdle() {
        // Stop only if no new step came after the end. A stop inside the frame handler would wait for itself.
        guard let link, !lock.withLock({ isActive }) else { return }
        CVDisplayLinkStop(link)
    }

    private static func displayUnderPointer() -> CGDirectDisplayID {
        let point = CGEvent(source: nil)?.location ?? .zero
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return count > 0 ? display : CGMainDisplayID()
    }

    private static let secondsPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    deinit {
        if let link { CVDisplayLinkStop(link) }
    }
}
