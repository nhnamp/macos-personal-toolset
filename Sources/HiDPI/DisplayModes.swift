import AppKit
import CoreGraphics
import ToolsetCore

/// A "looks like" size, such as 2048 × 1152. A HiDPI mode draws it with 4 pixels for each point.
public struct HiDPISize: Codable, Hashable, Identifiable {
    public var width: Int
    public var height: Int
    public var id: String { "\(width)x\(height)" }
    public var label: String { "\(width) × \(height)" }
}

/// One entry of the WindowServer mode table.
struct DisplayMode {
    let index: Int32
    let width: Int
    let height: Int
    let refresh: Int
    let isHiDPI: Bool
    var size: HiDPISize { HiDPISize(width: width, height: height) }
}

/// An external display and the HiDPI sizes that macOS has for it.
public struct ExternalDisplay: Identifiable {
    public let id: CGDirectDisplayID
    /// Vendor, model, and serial number. It stays the same when the display connects again.
    public let key: String
    public let name: String
    /// HiDPI sizes with the aspect ratio of the panel, largest first.
    public let sizes: [HiDPISize]
    /// Nil when the current mode is not a HiDPI mode.
    public let currentSize: HiDPISize?
    /// Such as "2048 × 1152 HiDPI, 120 Hz".
    public let currentText: String
}

/// Reads and sets modes through the private CGS functions, as BetterDisplay does.
enum DisplayModes {
    /// Byte offsets in the 212-byte mode description (`CGSDisplayModeDescription`).
    private enum Offset {
        static let width = 8, height = 12, refresh = 190, density = 208, size = 212
    }

    static func externalDisplays() -> [ExternalDisplay] {
        guard PrivateAPIs.canSetHiddenModes else { return [] }
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map(describe)
    }

    static func key(of display: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))"
    }

    /// Selects the HiDPI mode of this size with the highest refresh rate. Returns false when there is no such mode.
    @discardableResult
    static func select(_ size: HiDPISize, on display: CGDirectDisplayID) -> Bool {
        guard let configure = PrivateAPIs.configureMode,
              let mode = modes(of: display).filter({ $0.isHiDPI && $0.size == size }).max(by: { $0.refresh < $1.refresh })
        else { return false }
        if currentIndex(of: display) == mode.index { return true }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard configure(config, display, mode.index) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    private static func describe(_ display: CGDirectDisplayID) -> ExternalDisplay {
        let all = modes(of: display)
        // The largest 1x mode gives the aspect ratio of the panel.
        let native = all.filter { !$0.isHiDPI }.max { $0.width * $0.height < $1.width * $1.height }
        let aspect = native.map { Double($0.width) / Double($0.height) } ?? 16.0 / 9.0
        let sizes = Set(all.filter { $0.isHiDPI && $0.width >= 1024 && abs(Double($0.width) / Double($0.height) - aspect) < 0.02 }.map(\.size))
            .sorted { $0.width > $1.width }

        let current = currentIndex(of: display).flatMap { index in all.first { $0.index == index } }
        let text = current.map { "\($0.size.label)\($0.isHiDPI ? " HiDPI" : ""), \($0.refresh) Hz" } ?? "Unknown"
        return ExternalDisplay(
            id: display, key: key(of: display), name: name(of: display), sizes: sizes,
            currentSize: current?.isHiDPI == true ? current?.size : nil, currentText: text
        )
    }

    private static func modes(of display: CGDirectDisplayID) -> [DisplayMode] {
        guard let getCount = PrivateAPIs.getModeCount, let getDescription = PrivateAPIs.getModeDescription else { return [] }
        var count: Int32 = 0
        getCount(display, &count)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Offset.size, alignment: 4)
        defer { buffer.deallocate() }
        return (0..<max(count, 0)).map { index in
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Offset.size)
            getDescription(display, index, buffer, Int32(Offset.size))
            return DisplayMode(
                index: index,
                width: Int(buffer.load(fromByteOffset: Offset.width, as: UInt32.self)),
                height: Int(buffer.load(fromByteOffset: Offset.height, as: UInt32.self)),
                refresh: Int(buffer.load(fromByteOffset: Offset.refresh, as: UInt16.self)),
                isHiDPI: buffer.load(fromByteOffset: Offset.density, as: Float.self) > 1.5
            )
        }
    }

    private static func currentIndex(of display: CGDirectDisplayID) -> Int32? {
        guard let getCurrent = PrivateAPIs.getCurrentMode else { return nil }
        var index: Int32 = -1
        getCurrent(display, &index)
        return index >= 0 ? index : nil
    }

    private static func name(of display: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        return screen?.localizedName ?? "Display \(display)"
    }
}
