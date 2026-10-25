import AppKit
import SwiftUI
import ToolsetCore

/// Keeps a desktop (Spaces) arrangement for each display setup, and applies it when a display
/// connects or disconnects. This feature was the separate app Dispace.
public final class SpaceProfiles: NSObject, ObservableObject, ToolsetFeature {
    public let id = "space-profiles"
    public let title = "Space Profiles"
    public let summary = "Restores your desktops and windows when you connect or disconnect a display."
    public let needsAccessibility = true

    static let dispaceBundleId = "com.nhaatjnamphan.Dispace"

    @Published private(set) var profiles: [SetupKind: Profile]
    @Published private(set) var isBusy = false
    /// The setup of the displays that are connected now. Nil when the built-in display is off.
    @Published private(set) var currentKind = DisplaySetup.current().kind
    @Published private(set) var recentActivity: [String] = []

    var autoSwitch: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoSwitchKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.autoSwitchKey)
            Log.write(newValue ? "Automatic switching is on." : "Automatic switching is off.")
        }
    }

    private static let autoSwitchKey = "SpaceProfiles.autoSwitch"
    private let watcher: DisplayWatcher
    private let workQueue = DispatchQueue(label: "SpaceProfiles.work")
    /// The setup that the last automatic switch handled. Wake events with the same setup do nothing.
    private var lastKind: SetupKind?
    private var isRunning = false

    /// The host passes the toolset's shared display watcher.
    public init(watcher: DisplayWatcher) {
        self.watcher = watcher
        let imported = ProfileStore.importFromDispaceIfNeeded()
        profiles = ProfileStore.load()
        super.init()
        if let imported {
            Self.importAutoSwitchFromDispace()
            let names = imported.copied.map(\.rawValue).joined(separator: " and ")
            let noun = imported.copied.count == 1 ? "profile" : "profiles"
            Log.write(names.isEmpty ? "Copied no profile from Dispace." : "Copied the \(names) \(noun) from Dispace.")
            for kind in imported.skipped {
                Log.write("Not copied: the \(kind.rawValue) profile of Dispace has the small Stage Manager frames. Save it again.")
            }
        }
        watcher.subscribeToChanges { [weak self] in self?.displaysChanged() }
        NotificationCenter.default.addObserver(forName: Log.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.recentActivity = Log.recent
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        watcher.start()
        // A profile applies at the next display change, not at launch.
        lastKind = DisplaySetup.current().kind
        currentKind = lastKind
        let missing = SkyLight.missingSymbols
        Log.write(missing.isEmpty ? "Space Profiles started." : "Space Profiles started. Missing private symbols: \(missing.joined(separator: ", ")).")
    }

    /// A switch that runs now ends normally. Mission Control must not stay open.
    public func stop() {
        guard isRunning else { return }
        watcher.stop()
        isRunning = false
    }

    public func menuItems() -> [NSMenuItem] {
        refresh()
        var items: [NSMenuItem] = [disabledItem(statusLine)]
        if Self.isDispaceRunning {
            items.append(disabledItem("Dispace also switches profiles. Quit Dispace."))
        }
        let save = NSMenuItem(title: "Save Current Arrangement", action: #selector(saveFromMenu), keyEquivalent: "")
        save.target = self
        save.isEnabled = canSave
        items.append(save)
        if let kind = currentKind, !Self.isDispaceRunning {
            let apply = NSMenuItem(title: "Apply Now", action: #selector(applyFromMenu), keyEquivalent: "")
            apply.target = self
            apply.isEnabled = canApply(kind)
            items.append(apply)
        }
        return items
    }

    public func makeSettingsSections() -> AnyView {
        AnyView(SpaceProfilesSettingsView(profiles: self))
    }

    static var isDispaceRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: dispaceBundleId).isEmpty
    }

    /// Reads the display setup and the activity log again.
    func refresh() {
        currentKind = DisplaySetup.current().kind
        recentActivity = Log.recent
    }

    var canSave: Bool { currentKind != nil && !isBusy }

    func canApply(_ kind: SetupKind) -> Bool {
        currentKind == kind && !isBusy && profiles[kind] != nil && WindowAX.isTrusted && SkyLight.missingSymbols.isEmpty
    }

    // MARK: Display changes

    /// The watcher calls this when the displays are stable.
    private func displaysChanged() {
        guard isRunning else { return }
        refresh()
        displaysSettled(attempt: 0)
    }

    private func displaysSettled(attempt: Int) {
        guard isRunning else { return }
        // A switch is still running (for example, the display was reconnected during it).
        // Check again when it ends, so the newest setup is not skipped.
        if isBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.displaysSettled(attempt: attempt) }
            return
        }
        let setup = DisplaySetup.current()
        guard setup.kind != lastKind else { return }

        // WindowServer can need a moment before it gives Spaces to a new display.
        let layout = SkyLight.displaySpaces()
        let allManaged = setup.roles.allSatisfy { role in setup.displayID(for: role).map { layout[$0] != nil } ?? false }
        if !allManaged && attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.displaysSettled(attempt: attempt + 1) }
            return
        }

        lastKind = setup.kind
        guard let kind = setup.kind else {
            Log.write("The built-in display is off. No profile applies.")
            return
        }
        Log.write("Display setup changed to \(kind.rawValue).")
        guard autoSwitch else { Log.write("Automatic switching is off."); return }
        guard !Self.isDispaceRunning else { Log.write("Dispace is running, so Space Profiles does not switch. Quit Dispace."); return }
        guard let profile = profiles[kind] else { Log.write("No \(kind.rawValue) profile is saved yet."); return }
        apply(profile, kind: kind, setup: setup)
    }

    // MARK: Actions

    /// Saves the arrangement of the current setup. `completion` gets true when the file is written.
    func saveCurrentArrangement(completion: ((Bool) -> Void)? = nil) {
        let setup = DisplaySetup.current()
        guard let kind = setup.kind, !isBusy else { completion?(false); return }
        guard Displays.haveSeparateSpaces else {
            Log.write("Not saved: turn on \"Displays have separate Spaces\" first.")
            completion?(false)
            return
        }
        isBusy = true
        workQueue.async { [weak self] in
            let profile = Snapshot.capture(setup: setup)
            DispatchQueue.main.async {
                guard let self else { return }
                var updated = self.profiles
                updated[kind] = profile
                var saved = false
                do {
                    try ProfileStore.save(updated)
                    self.profiles = updated
                    saved = true
                    Log.write("Saved \(kind.rawValue): \(profile.windows.count) windows on \(profile.displays.map(\.spaceCount).reduce(0, +)) desktops.")
                } catch {
                    Log.write("Could not write the profile file: \(error.localizedDescription)")
                }
                self.lastKind = kind
                self.isBusy = false
                completion?(saved)
            }
        }
    }

    /// Deletes a saved profile. If the file cannot be written, the profile stays.
    func deleteProfile(_ kind: SetupKind) {
        guard !isBusy, profiles[kind] != nil else { return }
        var updated = profiles
        updated[kind] = nil
        do {
            try ProfileStore.save(updated)
            profiles = updated
            Log.write("Deleted the \(kind.rawValue) profile.")
        } catch {
            Log.write("Could not delete the \(kind.rawValue) profile: \(error.localizedDescription)")
        }
    }

    func applyNow(_ kind: SetupKind) {
        let setup = DisplaySetup.current()
        guard setup.kind == kind, let profile = profiles[kind] else { return }
        apply(profile, kind: kind, setup: setup)
    }

    private func apply(_ profile: Profile, kind: SetupKind, setup: DisplaySetup) {
        guard !isBusy else { return }
        isBusy = true
        workQueue.async { [weak self] in
            let summary = Applier.apply(profile, kind: kind, setup: setup) { Log.write($0) }
            Log.write(summary)
            DispatchQueue.main.async { self?.isBusy = false }
        }
    }

    @objc private func saveFromMenu() { saveCurrentArrangement() }

    @objc private func applyFromMenu() {
        if let kind = currentKind { applyNow(kind) }
    }

    // MARK: Helpers

    /// Example: "2-monitor: saved 25 Oct 2026 at 00:40, 15 windows".
    private var statusLine: String {
        if isBusy { return "Working…" }
        guard let kind = currentKind else { return "No profile: the built-in display is off" }
        guard let profile = profiles[kind] else { return "\(kind.rawValue): not saved" }
        return "\(kind.rawValue): saved \(Self.dateText(profile.savedAt)), \(profile.windows.count) windows"
    }

    static func dateText(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    /// Dispace kept the option in its own defaults. A missing value means on.
    private static func importAutoSwitchFromDispace() {
        guard UserDefaults.standard.object(forKey: autoSwitchKey) == nil,
              let value = UserDefaults(suiteName: dispaceBundleId)?.object(forKey: "autoSwitch") as? Bool else { return }
        UserDefaults.standard.set(value, forKey: autoSwitchKey)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
