import CoreGraphics
import Foundation

/// Tells the features when a display connects, and when the display setup changes.
/// The toolset runs one watcher, and each feature subscribes to it.
/// Each running feature calls `start()` once and `stop()` once. The watcher runs while one feature or more needs it.
public final class DisplayWatcher {
    private var handlers: [(CGDirectDisplayID) -> Void] = []
    private var changeHandlers: [() -> Void] = []
    private var settleWork: DispatchWorkItem?
    private var users = 0

    public init() {}

    /// The handler runs on the main queue, 2 seconds after the connection.
    /// WindowServer needs this time to load the mode table of the new display.
    public func subscribeToConnections(_ handler: @escaping (CGDirectDisplayID) -> Void) {
        handlers.append(handler)
    }

    /// The handler runs on the main queue, once the displays are stable: 2.5 seconds after the last change.
    /// macOS sends several callbacks for one change. A mode change (for example, from HiDPI) also counts,
    /// so the handler reads the display bounds after the new mode is in place.
    public func subscribeToChanges(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    public func start() {
        users += 1
        guard users == 1 else { return }
        CGDisplayRegisterReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    public func stop() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        settleWork?.cancel()
        settleWork = nil
        CGDisplayRemoveReconfigurationCallback(displayChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func connected(_ display: CGDirectDisplayID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.users > 0 else { return }
            for handler in self.handlers { handler(display) }
        }
    }

    fileprivate func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.users > 0 else { return }
            self.settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.users > 0 else { return }
                for handler in self.changeHandlers { handler() }
            }
            self.settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
    }
}

/// macOS calls this twice for each change: before it (`beginConfigurationFlag`) and after it.
private func displayChanged(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon, !flags.contains(.beginConfigurationFlag) else { return }
    let watcher = Unmanaged<DisplayWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.changed()
    if flags.contains(.addFlag) { watcher.connected(display) }
}
