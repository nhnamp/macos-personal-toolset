import AppKit
import WindowSwitcher

// Toolset: one menu bar app that hosts every feature.

// `Toolset --list [pid]` prints the windows that Option-Tab shows for an app, for tests from Terminal.
if CommandLine.arguments.dropFirst().first == "--list" {
    ListCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
