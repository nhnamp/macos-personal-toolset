import SwiftUI

/// The sections of the Keyboard Lock pane. The shortcut is fixed, so the pane shows it as text.
struct KeyboardLockSettingsView: View {
    @ObservedObject var lock: KeyboardLock

    var body: some View {
        Group {
            Section("Keys") {
                LabeledContent("Lock the keyboard", value: "Hold ⌘ ⇧ L for 3 s")
                LabeledContent("Unlock", value: "Click the lock, then wait 3 s")
                Button("Lock Now") { lock.lockNow() }
                note("Toolset takes ⌘⇧L from all apps. For example, Safari uses it to show or hide the sidebar.")
            }
            Section("Limits") {
                note("The power / Touch ID key still works. A press locks the screen or turns off the display.")
                note("While a password field is active, macOS sends the keys past Toolset. Then Toolset does not lock.")
                note("A press of Caps Lock or fn can change the Caps Lock light or the input source. Toolset puts both back at unlock.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
