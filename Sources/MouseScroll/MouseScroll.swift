import AppKit
import SwiftUI
import ToolsetCore

/// Smooth scrolling and an inverted scroll direction for a mouse wheel. The trackpad does not change.
/// This feature replaces two settings of the separate app Mac Mouse Fix.
public final class MouseScroll: ObservableObject, ToolsetFeature {
    public let id = "mouse-scroll"
    public let title = "Mouse Scrolling"
    public let summary = "Smooth scrolling and an inverted direction for a mouse wheel."
    public let needsAccessibility = true

    static let macMouseFixBundleIds = ["com.nuebling.mac-mouse-fix", "com.nuebling.mac-mouse-fix.helper"]

    @Published public var smooth: Bool {
        didSet { UserDefaults.standard.set(smooth, forKey: "MouseScroll.smooth"); apply() }
    }
    @Published public var invert: Bool {
        didSet { UserDefaults.standard.set(invert, forKey: "MouseScroll.invert"); apply() }
    }

    private let tap = ScrollTap()
    private var isRunning = false

    public init() {
        smooth = UserDefaults.standard.object(forKey: "MouseScroll.smooth") as? Bool ?? true
        invert = UserDefaults.standard.object(forKey: "MouseScroll.invert") as? Bool ?? true
    }

    public func start() {
        isRunning = true
        apply()
    }

    public func stop() {
        isRunning = false
        apply()
    }

    /// The tap exists only while the feature is on and at least one option is on.
    private func apply() {
        let options = ScrollTap.Options(smooth: smooth, invert: invert)
        tap.options = options
        if isRunning, options.smooth || options.invert {
            if !tap.start() { NSLog("Mouse Scrolling: the event tap did not start") }
        } else {
            tap.stop()
        }
    }

    static var isMacMouseFixRunning: Bool {
        macMouseFixBundleIds.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    public func menuItems() -> [NSMenuItem] {
        var items = [toggleItem("Smooth Scrolling", smooth, #selector(toggleSmooth)),
                     toggleItem("Invert Direction", invert, #selector(toggleInvert))]
        if Self.isMacMouseFixRunning {
            let item = NSMenuItem(title: "Mac Mouse Fix also changes scrolling. Quit it.", action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }
        return items
    }

    public func makeSettingsSections() -> AnyView {
        AnyView(MouseScrollSettingsView(mouse: self))
    }

    @objc private func toggleSmooth() { smooth.toggle() }
    @objc private func toggleInvert() { invert.toggle() }

    private func toggleItem(_ title: String, _ isOn: Bool, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }
}
