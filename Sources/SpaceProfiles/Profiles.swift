// The data model: display setups, saved profiles, live windows, and window matching.

import AppKit

/// The two display setups that Space Profiles knows. Each setup has one profile.
enum SetupKind: String, Codable, CaseIterable {
    case oneMonitor = "1-monitor"
    case twoMonitor = "2-monitor"

    var summary: String {
        switch self {
        case .oneMonitor: return "Built-in display only"
        case .twoMonitor: return "Built-in display + external display"
        }
    }
}

enum DisplayRole: String, Codable {
    case builtIn = "Built-in"
    case external = "External"
}

/// The displays that are connected now.
struct DisplaySetup: Equatable {
    let builtIn: CGDirectDisplayID?
    /// Only the first external display is used. Other external displays are ignored.
    let external: CGDirectDisplayID?

    static func current() -> DisplaySetup {
        let ids = Displays.activeDisplayIDs()
        return DisplaySetup(builtIn: ids.first { CGDisplayIsBuiltin($0) != 0 },
                            external: ids.first { CGDisplayIsBuiltin($0) == 0 })
    }

    /// Nil when the built-in display is off (for example, the lid is closed).
    var kind: SetupKind? {
        guard builtIn != nil else { return nil }
        return external == nil ? .oneMonitor : .twoMonitor
    }

    var roles: [DisplayRole] { kind == .twoMonitor ? [.builtIn, .external] : [.builtIn] }

    func displayID(for role: DisplayRole) -> CGDirectDisplayID? {
        role == .builtIn ? builtIn : external
    }

    func role(of displayID: CGDirectDisplayID) -> DisplayRole? {
        if displayID == builtIn { return .builtIn }
        if displayID == external { return .external }
        return nil
    }
}

struct SavedDisplay: Codable {
    let role: DisplayRole
    /// Number of normal desktops (full-screen app Spaces are not counted).
    let spaceCount: Int
}

struct SavedWindow: Codable {
    let windowID: UInt32
    let bundleID: String
    let appName: String
    let title: String
    let role: DisplayRole
    /// Position of the Space among the normal desktops of the display, starting at 0.
    let spaceIndex: Int
    /// Frame relative to the top-left corner of the display.
    let frame: CGRect
}

struct Profile: Codable {
    let savedAt: Date
    let displays: [SavedDisplay]
    let windows: [SavedWindow]

    /// True when most windows have the small frame of the Stage Manager strip.
    /// Dispace saved these frames when Stage Manager was on.
    var hasStripFrames: Bool {
        let small = windows.filter { $0.frame.width < 300 && $0.frame.height < 300 }
        return !windows.isEmpty && small.count * 2 > windows.count
    }

    /// One line for each saved desktop, for example ("Built-in, desktop 1", "Microsoft Edge, Zalo").
    func desktops() -> [(name: String, apps: String)] {
        displays.flatMap { display in
            (0..<display.spaceCount).map { index in
                let apps = windows.filter { $0.role == display.role && $0.spaceIndex == index }.map(\.appName)
                let names = Array(NSOrderedSet(array: apps)) as? [String] ?? []
                return ("\(display.role.rawValue), desktop \(index + 1)", names.isEmpty ? "Empty" : names.joined(separator: ", "))
            }
        }
    }
}

/// A window that exists now.
struct LiveWindow {
    let windowID: UInt32
    let pid: pid_t
    let bundleID: String
    let appName: String
    let displayID: CGDirectDisplayID
    let spaceID: UInt64
    let spaceIndex: Int
    let frame: CGRect
}

enum Snapshot {
    /// Lists the normal windows of regular apps on all desktops of the setup's displays.
    /// Windows on more than one Space (assigned to all desktops), minimized windows, and
    /// windows in full-screen Spaces are not included.
    static func liveWindows(setup: DisplaySetup, layout: [CGDirectDisplayID: DisplaySpaces]) -> [LiveWindow] {
        var placements: [UInt32: [(displayID: CGDirectDisplayID, spaceID: UInt64, index: Int)]] = [:]
        for role in setup.roles {
            guard let displayID = setup.displayID(for: role), let display = layout[displayID] else { continue }
            for (index, spaceID) in display.userSpaceIDs.enumerated() {
                for windowID in SkyLight.windows(onSpace: spaceID) {
                    placements[windowID, default: []].append((displayID, spaceID, index))
                }
            }
        }

        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [LiveWindow] = []
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let places = placements[number.uint32Value], places.count == 1, let place = places.first,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                  frame.width >= 50, frame.height >= 50 else { continue }
            result.append(LiveWindow(windowID: number.uint32Value, pid: pid,
                                     bundleID: app.bundleIdentifier ?? app.localizedName ?? "pid \(pid)",
                                     appName: app.localizedName ?? "?",
                                     displayID: place.displayID, spaceID: place.spaceID, spaceIndex: place.index,
                                     frame: frame))
        }
        return result.sorted { $0.windowID < $1.windowID }
    }

    /// Records the current arrangement as a profile.
    static func capture(setup: DisplaySetup) -> Profile {
        let layout = SkyLight.displaySpaces()
        let displays = setup.roles.compactMap { role -> SavedDisplay? in
            guard let displayID = setup.displayID(for: role), let display = layout[displayID] else { return nil }
            return SavedDisplay(role: role, spaceCount: display.userSpaceIDs.count)
        }
        let live = liveWindows(setup: setup, layout: layout)
        let elements = WindowAX.elements(for: live)
        let windows = live.compactMap { window -> SavedWindow? in
            guard let role = setup.role(of: window.displayID) else { return nil }
            let origin = Displays.bounds(of: window.displayID).origin
            let element = elements[window.windowID]
            let title = element.map(WindowAX.title(of:)) ?? ""
            let frame = element.flatMap(WindowAX.frame(of:)) ?? window.frame
            return SavedWindow(windowID: window.windowID, bundleID: window.bundleID, appName: window.appName,
                               title: title, role: role, spaceIndex: window.spaceIndex,
                               frame: frame.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        return Profile(savedAt: Date(), displays: displays, windows: windows)
    }
}

enum Matcher {
    /// Pairs saved windows with live windows. The rules depend on when the app started:
    /// - App running since the save: same window ID only. A saved window that is gone was
    ///   closed, so its place is not given to another window of the app.
    /// - App started after the save (logout, restart, or app restart): all window IDs are
    ///   new, and WindowServer can give an old number to another window. Window IDs are
    ///   ignored. The pair is the same title, else the next window of the app in order of creation.
    /// Windows without a pair are not touched.
    static func match(saved: [SavedWindow], live: [LiveWindow], savedAt: Date) -> [(saved: SavedWindow, live: LiveWindow)] {
        var free = live
        var pairs: [(saved: SavedWindow, live: LiveWindow)] = []
        var unmatched: [SavedWindow] = []

        for window in saved {
            if startedAfter(savedAt, bundleID: window.bundleID) {
                unmatched.append(window)
            } else if let index = free.firstIndex(where: { $0.windowID == window.windowID && $0.bundleID == window.bundleID }) {
                pairs.append((window, free.remove(at: index)))
            }
        }
        guard !unmatched.isEmpty else { return pairs }

        // Titles are read only for apps that still have unmatched windows.
        let candidates = free.filter { window in unmatched.contains { $0.bundleID == window.bundleID } }
        let titles = WindowAX.elements(for: candidates).mapValues(WindowAX.title(of:))
        var stillUnmatched: [SavedWindow] = []
        for window in unmatched {
            if !window.title.isEmpty,
               let index = free.firstIndex(where: { $0.bundleID == window.bundleID && titles[$0.windowID] == window.title }) {
                pairs.append((window, free.remove(at: index)))
            } else {
                stillUnmatched.append(window)
            }
        }
        for window in stillUnmatched.sorted(by: { $0.windowID < $1.windowID }) {
            if let index = free.firstIndex(where: { $0.bundleID == window.bundleID }) {
                pairs.append((window, free.remove(at: index)))
            }
        }
        return pairs
    }

    /// Returns true when every running instance of the app started after the date.
    /// An unknown start time counts as "before", so window IDs are trusted and nothing is guessed.
    static func startedAfter(_ date: Date, bundleID: String) -> Bool {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return !instances.isEmpty && instances.allSatisfy {
            ($0.launchDate ?? processStart($0.processIdentifier) ?? .distantPast) > date
        }
    }

    /// The start time of a process, from the kernel. macOS gives no `launchDate` for Finder.
    private static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}

/// Saves profiles as JSON in ~/Library/Application Support/Toolset/Space Profiles.json.
/// The file has the same format as the profiles.json of Dispace, the separate app that this feature replaces.
enum ProfileStore {
    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let dispaceURL = support.appendingPathComponent("Dispace/profiles.json")

    private static var fileURL: URL {
        let folder = support.appendingPathComponent("Toolset", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Space Profiles.json")
    }

    /// The result of the one-time copy of the Dispace profiles.
    struct DispaceImport {
        let copied: [SetupKind]
        let skipped: [SetupKind]
    }

    /// Copies the profiles of Dispace once, when Toolset has no profile file yet.
    /// A profile with Stage Manager strip frames is not copied: an apply would make its windows small.
    /// The Dispace file does not change, so Dispace can still be used.
    /// Returns nil when nothing was imported.
    static func importFromDispaceIfNeeded() -> DispaceImport? {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: fileURL.path), manager.fileExists(atPath: dispaceURL.path) else { return nil }
        var profiles = load(from: dispaceURL)
        let skipped = SetupKind.allCases.filter { profiles[$0]?.hasStripFrames == true }
        skipped.forEach { profiles[$0] = nil }
        // The file is written also when it is empty, so the import runs only once.
        guard (try? save(profiles)) != nil else { return nil }
        return DispaceImport(copied: SetupKind.allCases.filter { profiles[$0] != nil }, skipped: skipped)
    }

    static func load() -> [SetupKind: Profile] {
        load(from: fileURL)
    }

    private static func load(from url: URL) -> [SetupKind: Profile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode([String: Profile].self, from: data) else { return [:] }
        var result: [SetupKind: Profile] = [:]
        for (key, profile) in stored {
            if let kind = SetupKind(rawValue: key) { result[kind] = profile }
        }
        return result
    }

    static func save(_ profiles: [SetupKind: Profile]) throws {
        var stored: [String: Profile] = [:]
        for (kind, profile) in profiles { stored[kind.rawValue] = profile }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }
}
