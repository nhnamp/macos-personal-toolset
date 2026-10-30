import SwiftUI

/// The sections of the Mouse pane.
struct MouseSettingsView: View {
    @ObservedObject var mouse: Mouse
    @State private var macMouseFixRuns = Mouse.isMacMouseFixRunning

    var body: some View {
        Group {
            Section("Mouse Wheel") {
                Toggle("Smooth scrolling", isOn: $mouse.smooth)
                Picker("Glide", selection: $mouse.smoothness) {
                    ForEach(Smoothness.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!mouse.smooth)
                Toggle("Invert direction", isOn: $mouse.invert)
                note("These settings change only a mouse with a scroll wheel. The trackpad and the Magic Mouse do not change.")
                note("To change the speed, use System Settings > Mouse > Scrolling speed. Smooth scrolling glides only vertically, and only without modifier keys.")
                if macMouseFixRuns {
                    note("Mac Mouse Fix is running. It also changes the scroll events, so each step scrolls twice or in the wrong direction. Quit Mac Mouse Fix.")
                }
            }
            Section("Hold a Button") {
                ForEach(MouseButton.allCases) { button in
                    Picker(button.title, selection: holdBinding(button)) {
                        ForEach(ButtonAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                note("Hold a button for \(String(format: "%.1f", MouseTap.holdTime)) s to start its action. A short click and a drag work as before.")
                note("A button with an action sends its click when you release it, not when you press it.")
            }
        }
        .onAppear { macMouseFixRuns = Mouse.isMacMouseFixRunning }
    }

    private func holdBinding(_ button: MouseButton) -> Binding<ButtonAction> {
        Binding(get: { mouse.holdActions[button] ?? .none }, set: { mouse.setHoldAction($0, for: button) })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
