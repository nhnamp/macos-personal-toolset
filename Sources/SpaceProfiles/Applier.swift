// Applies a profile in three steps:
// 1. Add the desktops that are missing on each display (Mission Control).
// 2. Move each saved window to its desktop and frame (two passes).
// 3. Remove extra desktops that are empty and not visible (Mission Control).

import AppKit

enum Applier {
    /// Applies the profile and returns a one-line summary. Takes 2–6 seconds.
    /// Call it on a background queue, never on the main thread.
    static func apply(_ profile: Profile, kind: SetupKind, setup: DisplaySetup, log: (String) -> Void) -> String {
        guard SkyLight.canMoveWindows else {
            return "Cannot switch: this macOS version does not have the private function that moves windows."
        }
        guard WindowAX.isTrusted else { return "Cannot switch: Accessibility permission is missing." }

        // Step 1: add missing desktops.
        var added = 0
        var layout = SkyLight.displaySpaces()
        let additions = profile.displays.compactMap { saved -> (displayID: CGDirectDisplayID, count: Int)? in
            guard let displayID = setup.displayID(for: saved.role), let display = layout[displayID] else { return nil }
            let missing = saved.spaceCount - display.userSpaceIDs.count
            return missing > 0 ? (displayID, missing) : nil
        }
        if !additions.isEmpty {
            do {
                try MissionControl.withMissionControl {
                    for addition in additions {
                        try MissionControl.addSpaces(addition.count, toDisplay: addition.displayID)
                        added += addition.count
                    }
                }
            } catch {
                log("Could not add desktops: \(error).")
            }
            layout = SkyLight.displaySpaces()
        }

        // Step 2: place windows. macOS keeps moving windows for a few seconds after a
        // display change, so a second pass corrects what macOS moved after the first pass.
        let first = placeWindows(profile, setup: setup, layout: layout)
        sleep(2)
        layout = SkyLight.displaySpaces()
        let second = placeWindows(profile, setup: setup, layout: layout)

        // Step 3: remove extra desktops that are empty and not visible.
        var removed = 0
        var removals: [(displayID: CGDirectDisplayID, spaceID: UInt64)] = []
        for saved in profile.displays {
            guard let displayID = setup.displayID(for: saved.role), let display = layout[displayID] else { continue }
            for spaceID in display.userSpaceIDs.dropFirst(saved.spaceCount)
            where spaceID != display.currentSpaceID && SkyLight.windows(onSpace: spaceID, includeMinimized: true).isEmpty {
                removals.append((displayID, spaceID))
            }
        }
        if !removals.isEmpty {
            do {
                try MissionControl.withMissionControl {
                    for removal in removals.reversed() {
                        // Read the list again: each removal shifts the positions.
                        guard let spaces = SkyLight.displaySpaces()[removal.displayID]?.spaces,
                              let index = spaces.firstIndex(where: { $0.id == removal.spaceID }) else { continue }
                        try MissionControl.removeSpace(at: index, expectedCount: spaces.count, fromDisplay: removal.displayID)
                        removed += 1
                    }
                }
            } catch {
                log("Could not remove extra desktops: \(error).")
            }
        }

        let notFound = profile.windows.count - first.matched
        var parts = ["\(first.moved + second.moved) windows moved", "\(first.framed + second.framed) resized"]
        if added > 0 { parts.append("\(added) desktops added") }
        if removed > 0 { parts.append("\(removed) desktops removed") }
        if notFound > 0 { parts.append("\(notFound) saved windows skipped (closed, minimized, or full screen)") }
        if !second.failures.isEmpty {
            parts.append("failed: " + second.failures.joined(separator: ", "))
        }
        return "Applied \(kind.rawValue): " + parts.joined(separator: ", ") + "."
    }

    private struct PassResult {
        var matched = 0
        var moved = 0
        var framed = 0
        var failures: [String] = []
    }

    private static func placeWindows(_ profile: Profile, setup: DisplaySetup,
                                     layout: [CGDirectDisplayID: DisplaySpaces]) -> PassResult {
        var result = PassResult()
        let pairs = Matcher.match(saved: profile.windows, live: Snapshot.liveWindows(setup: setup, layout: layout),
                                  savedAt: profile.savedAt)
        result.matched = pairs.count

        // Find the target desktop and frame of each window.
        struct Plan { let window: LiveWindow; let spaceID: UInt64; let frame: CGRect }
        var plans: [Plan] = []
        for (saved, window) in pairs {
            guard let displayID = setup.displayID(for: saved.role),
                  let spaces = layout[displayID]?.userSpaceIDs, !spaces.isEmpty else { continue }
            let origin = Displays.bounds(of: displayID).origin
            plans.append(Plan(window: window, spaceID: spaces[min(saved.spaceIndex, spaces.count - 1)],
                              frame: saved.frame.offsetBy(dx: origin.x, dy: origin.y)))
        }

        // Move windows, one operation per target desktop. Check the result and try once more.
        var pending = plans.filter { $0.window.spaceID != $0.spaceID }
        result.moved = pending.count
        for attempt in 0..<2 where !pending.isEmpty {
            for (spaceID, group) in Dictionary(grouping: pending, by: \.spaceID) {
                SkyLight.moveWindows(group.map(\.window.windowID), toSpace: spaceID)
            }
            usleep(300_000)
            pending = pending.filter { !SkyLight.spaces(ofWindow: $0.window.windowID).contains($0.spaceID) }
            if attempt == 1 {
                result.failures += pending.map { "\($0.window.appName) (desktop)" }
            }
        }
        result.moved -= pending.count

        // Restore frames. A move to a desktop of another display can keep the old frame,
        // so the frame is read again after the move. The Accessibility frame comes first:
        // with Stage Manager on, the window server frame is the small frame in the side strip.
        SkyLight.waitForSpaceAnimations()
        let frames = currentFrames()
        let elements = WindowAX.elements(for: plans.map(\.window))
        let reframes = plans.filter { plan in
            let current = elements[plan.window.windowID].flatMap(WindowAX.frame(of:)) ?? frames[plan.window.windowID]
            return current.map { !isClose($0, plan.frame) } ?? false
        }
        for plan in reframes {
            if let element = elements[plan.window.windowID], WindowAX.setFrame(element, plan.frame) {
                result.framed += 1
            } else {
                result.failures.append("\(plan.window.appName) (frame)")
            }
        }
        return result
    }

    private static func currentFrames() -> [UInt32: CGRect] {
        var frames: [UInt32: CGRect] = [:]
        for entry in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            frames[number.uint32Value] = frame
        }
        return frames
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
