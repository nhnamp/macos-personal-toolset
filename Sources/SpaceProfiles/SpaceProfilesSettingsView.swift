import SwiftUI
import ToolsetCore

/// The sections of the Space Profiles pane: the display setup, one section for each profile,
/// the option, and the recent activity.
struct SpaceProfilesSettingsView: View {
    @ObservedObject var profiles: SpaceProfiles
    @State private var replacing: SetupKind?
    @State private var deleting: SetupKind?

    var body: some View {
        Group {
            Section("Displays") {
                LabeledContent("Connected now", value: profiles.currentKind?.summary ?? "External display only")
                LabeledContent("Active profile", value: profiles.currentKind?.rawValue ?? "None")
                ForEach(warnings, id: \.self) { note($0) }
            }
            ForEach(SetupKind.allCases, id: \.self) { kind in
                profileSection(kind)
            }
            Section {
                Toggle("Switch automatically when a display connects or disconnects",
                       isOn: Binding(get: { profiles.autoSwitch }, set: { profiles.autoSwitch = $0 }))
                note("Mission Control can open for about a second while desktops are added or removed.")
            }
            Section("Recent Activity") {
                if profiles.isBusy {
                    note("Working…")
                }
                if profiles.recentActivity.isEmpty {
                    note("No activity yet.")
                } else {
                    Text(profiles.recentActivity.suffix(6).joined(separator: "\n"))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear { profiles.refresh() }
        .alert("Replace the saved \(replacing?.rawValue ?? "") profile?", isPresented: isPresented($replacing), presenting: replacing) { _ in
            Button("Replace") { profiles.saveCurrentArrangement() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Toolset saves the desktops and windows that you have now.")
        }
        .alert("Delete the saved \(deleting?.rawValue ?? "") profile?", isPresented: isPresented($deleting), presenting: deleting) { kind in
            Button("Delete", role: .destructive) { profiles.deleteProfile(kind) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Toolset forgets the desktops and windows of this profile. Your windows do not move. You cannot undo this.")
        }
    }

    private func profileSection(_ kind: SetupKind) -> some View {
        let isCurrent = profiles.currentKind == kind
        let profile = profiles.profiles[kind]
        return Section {
            if let profile {
                LabeledContent("Saved", value: "\(SpaceProfiles.dateText(profile.savedAt)), \(profile.windows.count) windows")
                ForEach(profile.desktops(), id: \.name) { desktop in
                    LabeledContent(desktop.name, value: desktop.apps)
                }
            } else {
                note(isCurrent
                     ? "Not saved yet. Arrange your desktops and windows, then click Save Current Arrangement."
                     : "Not saved yet. Connect this display setup to save it.")
            }
            HStack {
                Button("Save Current Arrangement") {
                    if profile == nil { profiles.saveCurrentArrangement() } else { replacing = kind }
                }
                .disabled(!isCurrent || !profiles.canSave)
                Button("Apply Now") { profiles.applyNow(kind) }
                    .disabled(!profiles.canApply(kind))
                Spacer()
                Button("Delete…") { deleting = kind }
                    .disabled(profile == nil || profiles.isBusy)
            }
        } header: {
            Text(kind.rawValue + ": " + kind.summary.lowercased() + (isCurrent ? " (now)" : ""))
        }
    }

    private var warnings: [String] {
        var lines: [String] = []
        if SpaceProfiles.isDispaceRunning {
            lines.append("Dispace is running. It also switches profiles, so Toolset does not switch automatically. Quit Dispace.")
        }
        let missing = SkyLight.missingSymbols
        if !missing.isEmpty {
            lines.append("This macOS does not have: \(missing.joined(separator: ", ")). Toolset cannot move windows.")
        }
        if !Displays.haveSeparateSpaces {
            lines.append("Turn on \"Displays have separate Spaces\" in System Settings > Desktop & Dock, then log out and in.")
        }
        if Displays.rearrangeSpacesByRecentUse {
            lines.append("Turn off \"Automatically rearrange Spaces based on most recent use\" in System Settings > Desktop & Dock. It changes the order of your desktops.")
        }
        return lines
    }

    private func isPresented(_ kind: Binding<SetupKind?>) -> Binding<Bool> {
        Binding(get: { kind.wrappedValue != nil }, set: { if !$0 { kind.wrappedValue = nil } })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
