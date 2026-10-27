import AppKit
import ToolsetCore
import ApplicationServices

/// `Toolset --list [pid]` prints the windows that Option-Tab shows for an app, then exits.
/// Without a pid, it uses the frontmost app. Use it to test the window search from Terminal.
public enum ListCommand {
    public static func run(arguments: [String]) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        guard AXIsProcessTrusted() else {
            print("Error: this process has no Accessibility permission.")
            return
        }
        let app: NSRunningApplication?
        if let pidText = arguments.first {
            guard let pid = pid_t(pidText) else {
                print("Error: '\(pidText)' is not a process ID.")
                return
            }
            app = NSRunningApplication(processIdentifier: pid)
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else {
            print("Error: no app has this process ID.")
            return
        }

        let store = WindowStore()
        var isDone = false
        let start = Date()
        if store.searchIfNeeded(for: app, completion: { isDone = true }) {
            let deadline = Date().addingTimeInterval(WindowStore.searchTimeLimit + 1)
            while !isDone, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        let searchTime = Date().timeIntervalSince(start)
        let windows = store.windows(of: app)

        print("Mode: \(PrivateAPIs.canFindWindowsOnAllSpaces ? "all Spaces" : "public APIs only (this Space)")")
        print("App: \(app.localizedName ?? "?") (pid \(app.processIdentifier)), \(windows.count) windows, search \(Int(searchTime * 1000)) ms")

        // For a browser, each line also tells the page URL and which icon the panel shows: the website icon or the app icon.
        var iconNotes = Array(repeating: "", count: windows.count)
        if WindowIcons.hasFavicons(app) {
            if FaviconSources.source(for: app)?.needsDataAccess == true {
                print("Website icons: no read access to the browser data folder. Give Full Disk Access to the app that runs this command.")
            }
            var favicons: [NSImage?]?
            let iconStart = Date()
            WindowIcons().loadFavicons(for: windows, of: app) { favicons = $0 }
            let deadline = Date().addingTimeInterval(5)
            while favicons == nil, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            let found = favicons ?? []
            iconNotes = windows.indices.map { index in
                let url = WindowIcons.pageURL(of: windows[index].element)?.absoluteString ?? "no URL"
                guard index < found.count, let favicon = found[index] else { return " {icon: app, \(url)}" }
                return " {icon: website, \(favicon.representations.first?.pixelsWide ?? 0) px, \(url)}"
            }
            print("Website icons: \(found.compactMap { $0 }.count) of \(windows.count) windows, lookup \(Int(Date().timeIntervalSince(iconStart) * 1000)) ms")
        }
        for (index, window) in windows.enumerated() {
            let id = window.windowId.map(String.init) ?? "-"
            print("\(index + 1). [\(id)]\(window.isMinimized ? " [minimized]" : "")\(iconNotes[index]) \(window.title)")
        }
    }
}
