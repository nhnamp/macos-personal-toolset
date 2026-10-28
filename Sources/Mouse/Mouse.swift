import AppKit
import SwiftUI
import ToolsetCore

/// Smooth scrolling and an inverted scroll direction for a mouse wheel, and an action for each held extra button.
/// The trackpad does not change. This feature replaces the separate app Mac Mouse Fix.
public final class Mouse: ObservableObject, ToolsetFeature {
    /// The id and the scroll setting keys are from the first name, "Mouse Scrolling". They stay, so the saved settings stay.
    public let id = "mouse-scroll"
    public let title = "Mouse"
    public let summary = "Smooth scrolling, an inverted direction, and actions for held buttons."
    public let needsAccessibility = true

    static let macMouseFixBundleIds = ["com.nuebling.mac-mouse-fix", "com.nuebling.mac-mouse-fix.helper"]

    @Published public var smooth: Bool {
        didSet { UserDefaults.standard.set(smooth, forKey: "MouseScroll.smooth"); apply() }
    }
    @Published public var invert: Bool {
        didSet { UserDefaults.standard.set(invert, forKey: "MouseScroll.invert"); apply() }
    }
    /// The action for a hold of each extra button.
    @Published public private(set) var holdActions: [MouseButton: ButtonAction]

    private let tap = MouseTap()
    private var isRunning = false

    public init() {
        smooth = UserDefaults.standard.object(forKey: "MouseScroll.smooth") as? Bool ?? true
        invert = UserDefaults.standard.object(forKey: "MouseScroll.invert") as? Bool ?? true
        holdActions = Dictionary(uniqueKeysWithValues: MouseButton.allCases.map { button in
            let saved = UserDefaults.standard.string(forKey: Self.holdKey(button)).flatMap(ButtonAction.init(rawValue:))
            return (button, saved ?? button.defaultHoldAction)
        })
    }

    public func setHoldAction(_ action: ButtonAction, for button: MouseButton) {
        holdActions[button] = action
        UserDefaults.standard.set(action.rawValue, forKey: Self.holdKey(button))
        apply()
    }

    private static func holdKey(_ button: MouseButton) -> String {
        "Mouse.hold.\(button)"
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
        let actions = holdActions.filter { $0.value != .none }
        let options = MouseTap.Options(smooth: smooth, invert: invert,
                                       holdActions: Dictionary(uniqueKeysWithValues: actions.map { ($0.key.rawValue, $0.value) }))
        tap.options = options
        if isRunning, options.needsTap {
            if !tap.start() { NSLog("Mouse: the event tap did not start") }
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
        AnyView(MouseSettingsView(mouse: self))
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
