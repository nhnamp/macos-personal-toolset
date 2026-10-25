import AppKit
import SwiftUI

/// What the host app needs from each feature.
/// The host has one on/off switch for each feature. A feature that is off is never started,
/// so it costs no CPU and no observers.
public protocol ToolsetFeature: AnyObject {
    /// Stable key for saved settings, such as "input-memory".
    var id: String { get }
    /// Name in the sidebar and the menu, such as "Input Memory".
    var title: String { get }
    /// One line under the title in Settings.
    var summary: String { get }
    /// True when the feature reads or controls other apps' windows.
    var needsAccessibility: Bool { get }

    func start()
    func stop()
    /// At most three items for the menu bar menu, under the feature's section header.
    /// The host calls this each time the menu opens, so the items show the current state.
    func menuItems() -> [NSMenuItem]
    /// The `Section`s of the feature's settings pane. The host puts them in a grouped `Form`,
    /// under a header with the title, the summary, and the on/off switch.
    func makeSettingsSections() -> AnyView
}
