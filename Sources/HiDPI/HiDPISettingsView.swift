import SwiftUI
import ToolsetCore

/// The sections of the HiDPI pane: one section for each connected external display.
struct HiDPISettingsView: View {
    @ObservedObject var hidpi: HiDPI
    @ObservedObject var settings: HiDPISettings

    var body: some View {
        Group {
            if !PrivateAPIs.canSetHiddenModes {
                Section { note("This macOS does not have the functions that HiDPI uses.") }
            } else if hidpi.displays.isEmpty {
                Section { note("No external display is connected.") }
            }
            ForEach(hidpi.displays) { display in
                Section(display.name) {
                    Picker("Looks like", selection: binding(for: display)) {
                        Text("Not managed").tag(HiDPISize?.none)
                        Divider()
                        ForEach(display.sizes) { Text($0.label).tag(HiDPISize?.some($0)) }
                    }
                    LabeledContent("Current mode", value: display.currentText)
                }
            }
            Section {
                note("Toolset selects the size at launch and each time the display connects. \"Not managed\" keeps the current mode. Larger sizes use more GPU memory.")
            }
        }
        .onAppear { hidpi.refresh() }
    }

    private func binding(for display: ExternalDisplay) -> Binding<HiDPISize?> {
        Binding(get: { settings.sizes[display.key] }, set: { hidpi.choose($0, for: display) })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
