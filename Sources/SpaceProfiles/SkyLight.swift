// Bindings to private SkyLight (WindowServer) functions.
// All symbols load at run time. If a macOS update removes a symbol, the related
// feature reports "unavailable" and the app keeps running.

import AppKit
import MachO

/// One Space as Mission Control shows it.
struct Space {
    let id: UInt64
    /// 0 = normal desktop ("user Space"), 4 = full-screen app Space.
    let type: Int
    var isUser: Bool { type == 0 }
}

/// The Spaces of one display, in Mission Control order.
struct DisplaySpaces {
    let displayID: CGDirectDisplayID
    let spaces: [Space]
    let currentSpaceID: UInt64
    var userSpaceIDs: [UInt64] { spaces.filter(\.isUser).map(\.id) }
}

enum SkyLight {
    typealias ConnectionID = Int32

    private static let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private static let handle = dlopen(path, RTLD_NOW)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    // MARK: Exported private functions

    private static let mainConnectionID = symbol("SLSMainConnectionID", as: (@convention(c) () -> ConnectionID).self)
    private static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: (@convention(c) (ConnectionID) -> Unmanaged<CFArray>?).self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: (@convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?).self)
    private static let copyWindowsWithOptionsAndTags = symbol("SLSCopyWindowsWithOptionsAndTags", as: (@convention(c) (ConnectionID, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?).self)
    private static let windowQueryWindows = symbol("SLSWindowQueryWindows", as: (@convention(c) (ConnectionID, CFArray, Int32) -> Unmanaged<CFTypeRef>?).self)
    private static let windowQueryResultCopyWindows = symbol("SLSWindowQueryResultCopyWindows", as: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self)
    private static let iteratorAdvance = symbol("SLSWindowIteratorAdvance", as: (@convention(c) (CFTypeRef) -> Bool).self)
    private static let iteratorGetTags = symbol("SLSWindowIteratorGetTags", as: (@convention(c) (CFTypeRef) -> UInt64).self)
    private static let iteratorGetAttributes = symbol("SLSWindowIteratorGetAttributes", as: (@convention(c) (CFTypeRef) -> UInt64).self)
    private static let iteratorGetParentID = symbol("SLSWindowIteratorGetParentID", as: (@convention(c) (CFTypeRef) -> UInt32).self)
    private static let iteratorGetWindowID = symbol("SLSWindowIteratorGetWindowID", as: (@convention(c) (CFTypeRef) -> UInt32).self)
    private static let iteratorGetLevel = symbol("SLSWindowIteratorGetLevel", as: (@convention(c) (CFTypeRef) -> Int32).self)
    private static let managedDisplayIsAnimating = symbol("SLSManagedDisplayIsAnimating", as: (@convention(c) (ConnectionID, CFString) -> Bool).self)

    // MARK: Hidden function for moving windows
    //
    // Since macOS 14.5, SLSMoveWindowsToManagedSpace silently ignores windows of other apps.
    // macOS 26 and 27 still accept a "bridged" move operation. The function that sends it is
    // not exported, so we find it in the SkyLight symbol table (same method as yabai 7.1.25).

    private static let performBridgedOperation: (@convention(c) (UnsafeMutableRawPointer) -> Int64)? = {
        let name = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
        guard let pointer = hiddenSymbol(name) else { return nil }
        return unsafeBitCast(pointer, to: (@convention(c) (UnsafeMutableRawPointer) -> Int64).self)
    }()
    private static let moveOperationClass: AnyClass? = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
    private static let objcMsgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") // RTLD_DEFAULT

    /// The names of required private symbols that this macOS version does not have.
    static var missingSymbols: [String] {
        var missing: [String] = []
        if mainConnectionID == nil { missing.append("SLSMainConnectionID") }
        if copyManagedDisplaySpaces == nil { missing.append("SLSCopyManagedDisplaySpaces") }
        if copySpacesForWindows == nil { missing.append("SLSCopySpacesForWindows") }
        if copyWindowsWithOptionsAndTags == nil || windowQueryWindows == nil || windowQueryResultCopyWindows == nil
            || iteratorAdvance == nil || iteratorGetTags == nil || iteratorGetAttributes == nil
            || iteratorGetParentID == nil || iteratorGetWindowID == nil || iteratorGetLevel == nil {
            missing.append("SLSWindowIterator functions")
        }
        if performBridgedOperation == nil { missing.append("SLSPerformAsynchronousBridgedWindowManagementOperation") }
        if moveOperationClass == nil { missing.append("SLSBridgedMoveWindowsToManagedSpaceOperation") }
        return missing
    }

    private static var connection: ConnectionID { mainConnectionID?() ?? 0 }

    // MARK: Spaces

    /// Returns the Spaces of each display, keyed by display ID.
    /// Displays that WindowServer does not manage yet (for example, a display that was
    /// connected a moment ago) are not in the result.
    static func displaySpaces() -> [CGDirectDisplayID: DisplaySpaces] {
        guard let copy = copyManagedDisplaySpaces,
              let list = copy(connection)?.takeRetainedValue() as? [[String: Any]] else { return [:] }

        var displayIDsByUUID: [String: CGDirectDisplayID] = [:]
        for displayID in Displays.activeDisplayIDs() {
            displayIDsByUUID[Displays.uuid(of: displayID)] = displayID
        }

        var result: [CGDirectDisplayID: DisplaySpaces] = [:]
        for entry in list {
            guard let identifier = entry["Display Identifier"] as? String else { continue }
            // "Main" is used when "Displays have separate Spaces" is off.
            let displayID = identifier == "Main" ? CGMainDisplayID() : displayIDsByUUID[identifier.uppercased()]
            guard let displayID else { continue }
            let spaces = (entry["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> Space? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
                return Space(id: id, type: (space["type"] as? NSNumber)?.intValue ?? 0)
            }
            let current = ((entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
            result[displayID] = DisplaySpaces(displayID: displayID, spaces: spaces, currentSpaceID: current)
        }
        return result
    }

    /// Waits (at most 2 s) while a desktop switch animation runs on any display.
    /// During the animation, WindowServer reports window frames moved by whole screen widths.
    static func waitForSpaceAnimations() {
        guard let isAnimating = managedDisplayIsAnimating else { return }
        for _ in 0..<40 {
            let animating = Displays.activeDisplayIDs().contains { isAnimating(connection, Displays.uuid(of: $0) as CFString) }
            if !animating { return }
            usleep(50_000)
        }
    }

    /// Returns the IDs of the Spaces that contain the window.
    static func spaces(ofWindow windowID: UInt32) -> [UInt64] {
        guard let copy = copySpacesForWindows,
              let list = copy(connection, 7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        else { return [] }
        return list.map(\.uint64Value)
    }

    /// Returns the normal app windows on a Space, also when the Space is not visible.
    /// The filter is the same as yabai's `space_window_list_for_connection`.
    /// It removes invisible helper windows.
    static func windows(onSpace spaceID: UInt64, includeMinimized: Bool = false) -> [UInt32] {
        guard let copyWindows = copyWindowsWithOptionsAndTags, let query = windowQueryWindows,
              let copyResult = windowQueryResultCopyWindows, let advance = iteratorAdvance,
              let getTags = iteratorGetTags, let getAttributes = iteratorGetAttributes,
              let getParentID = iteratorGetParentID, let getWindowID = iteratorGetWindowID,
              let getLevel = iteratorGetLevel else { return [] }

        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let spaceList = [NSNumber(value: spaceID)] as CFArray
        let options: UInt32 = includeMinimized ? 0x7 : 0x2
        guard let windowList = copyWindows(connection, 0, spaceList, options, &setTags, &clearTags)?.takeRetainedValue(),
              CFArrayGetCount(windowList) > 0,
              let queryResult = query(connection, windowList, Int32(CFArrayGetCount(windowList)))?.takeRetainedValue(),
              let iterator = copyResult(queryResult)?.takeRetainedValue() else { return [] }

        var result: [UInt32] = []
        while advance(iterator) {
            let tags = getTags(iterator)
            let attributes = getAttributes(iterator)
            let level = getLevel(iterator)
            guard getParentID(iterator) == 0, level == 0 || level == 3 || level == 8 else { continue }
            let isOrderedIn = (attributes & 0x2) != 0 || (tags & 0x400000000000000) != 0
            let isMinimized = (attributes == 0x0 || attributes == 0x1)
                && ((tags & 0x1000000000000000) != 0 || (tags & 0x300000000000000) != 0)
            let isDocumentOrPanel = (tags & 0x1) != 0 || ((tags & 0x2) != 0 && (tags & 0x80000000) != 0)
            if isDocumentOrPanel && (isOrderedIn || (includeMinimized && isMinimized)) {
                result.append(getWindowID(iterator))
            }
        }
        return result
    }

    // MARK: Move windows

    static var canMoveWindows: Bool { performBridgedOperation != nil && moveOperationClass != nil && objcMsgSend != nil }

    /// Asks WindowServer to move windows to a Space. The operation is asynchronous:
    /// read the result back with `spaces(ofWindow:)`.
    static func moveWindows(_ windowIDs: [UInt32], toSpace spaceID: UInt64) {
        guard let perform = performBridgedOperation, let moveOperationClass, let objcMsgSend, !windowIDs.isEmpty else { return }

        // Objective-C equivalent:
        //   op = [[SLSBridgedMoveWindowsToManagedSpaceOperation alloc] initWithWindows:ids spaceID:sid];
        //   SLSPerformAsynchronousBridgedWindowManagementOperation(op); [op release];
        typealias AllocFn = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeMutableRawPointer?
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer, UInt64) -> UnsafeMutableRawPointer?
        typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer, Selector) -> Void

        let windows = windowIDs.map { NSNumber(value: $0) } as NSArray
        withExtendedLifetime(windows) {
            let classPointer = UnsafeRawPointer(Unmanaged.passUnretained(moveOperationClass as AnyObject).toOpaque())
            guard let allocated = unsafeBitCast(objcMsgSend, to: AllocFn.self)(classPointer, NSSelectorFromString("alloc")),
                  let operation = unsafeBitCast(objcMsgSend, to: InitFn.self)(
                      allocated, NSSelectorFromString("initWithWindows:spaceID:"),
                      UnsafeRawPointer(Unmanaged.passUnretained(windows).toOpaque()), spaceID)
            else { return }
            _ = perform(operation)
            unsafeBitCast(objcMsgSend, to: ReleaseFn.self)(operation, NSSelectorFromString("release"))
        }
    }

    // MARK: Symbol table lookup

    /// Finds a non-exported symbol in the SkyLight image that is loaded in this process.
    private static func hiddenSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        for index in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(index), String(cString: imageName) == path,
                  let rawHeader = _dyld_get_image_header(index) else { continue }
            let header = UnsafeRawPointer(rawHeader).assumingMemoryBound(to: mach_header_64.self)
            let slide = _dyld_get_image_vmaddr_slide(index)

            var linkedit: segment_command_64?
            var symtab: symtab_command?
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.load(as: load_command.self)
                if load.cmd == LC_SEGMENT_64 {
                    let segment = command.load(as: segment_command_64.self)
                    let segmentName = withUnsafeBytes(of: segment.segname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    if segmentName == "__LINKEDIT" { linkedit = segment }
                } else if load.cmd == LC_SYMTAB {
                    symtab = command.load(as: symtab_command.self)
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
            guard let linkedit, let symtab else { return nil }

            let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
            guard let strings = UnsafeRawPointer(bitPattern: base + Int(symtab.stroff)),
                  let symbols = UnsafeRawPointer(bitPattern: base + Int(symtab.symoff)) else { return nil }
            for symbolIndex in 0..<Int(symtab.nsyms) {
                let entry = symbols.load(fromByteOffset: symbolIndex * MemoryLayout<nlist_64>.stride, as: nlist_64.self)
                let symbolName = strings.advanced(by: Int(entry.n_un.n_strx)).assumingMemoryBound(to: CChar.self)
                if strcmp(symbolName, name) == 0 {
                    return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
                }
            }
            return nil
        }
        return nil
    }
}

/// Public CoreGraphics display helpers.
enum Displays {
    /// Active displays, without displays that only mirror another display.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func uuid(of displayID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "" }
        return (CFUUIDCreateString(nil, uuid) as String).uppercased()
    }

    /// Display bounds in global coordinates with the origin at the top left (same as Accessibility).
    static func bounds(of displayID: CGDirectDisplayID) -> CGRect { CGDisplayBounds(displayID) }

    /// True when "Displays have separate Spaces" is on in System Settings.
    static var haveSeparateSpaces: Bool {
        let value = CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? Bool
        return value != true
    }

    /// True when "Automatically rearrange Spaces based on most recent use" is on (the default).
    /// It changes the order of desktops, and profiles store desktops by position.
    static var rearrangeSpacesByRecentUse: Bool {
        let value = CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString) as? Bool
        return value ?? true
    }
}
