import AppKit
import ApplicationServices

/// Private macOS functions. The toolset finds them at run time with `dlsym`.
/// If a future macOS removes one, its value is nil and the features fall back to public APIs.
public enum PrivateAPIs {
    public typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    public typealias CreateWithRemoteTokenFunction = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    public typealias GetProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    public typealias SetFrontProcessFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    public typealias PostEventRecordFunction = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    /// Gives the window server ID (`CGWindowID`) of an Accessibility window.
    public static let getWindow: GetWindowFunction? = load("_AXUIElementGetWindow")
    /// Makes an Accessibility element from a token. This finds windows on other Spaces.
    public static let createWithRemoteToken: CreateWithRemoteTokenFunction? = load("_AXUIElementCreateWithRemoteToken")
    public static let getProcessForPID: GetProcessForPIDFunction? = load("GetProcessForPID")
    /// Brings a process and one of its windows to the front, on any Space.
    public static let setFrontProcess: SetFrontProcessFunction? = load("_SLPSSetFrontProcessWithOptions")
    /// Sends a raw event record to a process.
    public static let postEventRecord: PostEventRecordFunction? = load("SLPSPostEventRecordTo")

    public static var canFindWindowsOnAllSpaces: Bool { getWindow != nil && createWithRemoteToken != nil }
    public static var canFocusAcrossSpaces: Bool { getProcessForPID != nil && setFrontProcess != nil && postEventRecord != nil }

    // The full display mode table of WindowServer. It also has the HiDPI modes that
    // `CGDisplayCopyAllDisplayModes` and System Settings do not show.
    public typealias GetModeCountFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    public typealias GetModeDescriptionFunction = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Void
    public typealias GetCurrentModeFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Void
    public typealias ConfigureModeFunction = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError

    public static let getModeCount: GetModeCountFunction? = load("CGSGetNumberOfDisplayModes")
    public static let getModeDescription: GetModeDescriptionFunction? = load("CGSGetDisplayModeDescriptionOfLength")
    public static let getCurrentMode: GetCurrentModeFunction? = load("CGSGetCurrentDisplayMode")
    public static let configureMode: ConfigureModeFunction? = load("CGSConfigureDisplayMode")

    public static var canSetHiddenModes: Bool {
        getModeCount != nil && getModeDescription != nil && getCurrentMode != nil && configureMode != nil
    }

    private static let libraries: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY),
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
    ]

    private static func load<T>(_ name: String) -> T? {
        _ = libraries
        // -2 is RTLD_DEFAULT: search all loaded libraries.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
