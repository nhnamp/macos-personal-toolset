import SwiftUI
import ToolsetCore

/// The sections of the Window Switcher pane. The keys are fixed, so the pane shows them as text.
struct WindowSwitcherSettingsView: View {
    let openFullDiskAccess: () -> Void
    @State private var needsDataAccess = FaviconSources.needsDataAccess
    @State private var altTabRuns = WindowSwitcher.isAltTabRunning

    var body: some View {
        Group {
            Section("Keys") {
                LabeledContent("Open the list, next window", value: "⌥ Tab")
                LabeledContent("Previous window", value: "⌥ ⇧ Tab")
                LabeledContent("Focus the selected window", value: "Release ⌥")
                LabeledContent("Close the list", value: "⌥ Esc")
                if altTabRuns {
                    note("AltTab is running. It also uses Option-Tab, so a key press can go to AltTab. Quit AltTab, or change its shortcut.")
                }
            }
            Section("Windows") {
                LabeledContent("Spaces", value: PrivateAPIs.canFindWindowsOnAllSpaces ? "All Spaces" : "This Space only")
                note("The list shows up to \(WindowStore.maxWindows) windows, the most recent first.")
            }
            Section("Website Icons for Browsers") {
                LabeledContent("Browser data", value: needsDataAccess ? "Not allowed" : "Allowed")
                if needsDataAccess {
                    Button("Open Full Disk Access Settings…", action: openFullDiskAccess)
                }
                note("Browser rows show the icon of the website. Toolset reads it from the favicon file of the browser, which needs Full Disk Access. Without it, browser rows show the browser icon. Tested with Safari and Edge. Chrome, Brave, Arc, Vivaldi, Opera, and Chromium use the Edge reader.")
            }
        }
        .onAppear {
            needsDataAccess = FaviconSources.needsDataAccess
            altTabRuns = WindowSwitcher.isAltTabRunning
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
