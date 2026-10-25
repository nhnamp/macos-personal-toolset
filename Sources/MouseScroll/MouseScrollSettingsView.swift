import SwiftUI

/// The sections of the Mouse Scrolling pane.
struct MouseScrollSettingsView: View {
    @ObservedObject var mouse: MouseScroll
    @State private var macMouseFixRuns = MouseScroll.isMacMouseFixRunning

    var body: some View {
        Group {
            Section("Mouse Wheel") {
                Toggle("Smooth scrolling", isOn: $mouse.smooth)
                Toggle("Invert direction", isOn: $mouse.invert)
                note("These settings change only a mouse with a scroll wheel. The trackpad and the Magic Mouse do not change.")
                note("To change the speed, use System Settings > Mouse > Scrolling speed. Smooth scrolling glides only vertically, and only without modifier keys.")
                if macMouseFixRuns {
                    note("Mac Mouse Fix is running. It also changes the scroll events, so each step scrolls twice or in the wrong direction. Quit Mac Mouse Fix.")
                }
            }
        }
        .onAppear { macMouseFixRuns = MouseScroll.isMacMouseFixRunning }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
