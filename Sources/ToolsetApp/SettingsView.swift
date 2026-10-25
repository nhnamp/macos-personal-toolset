import SwiftUI
import ToolsetCore

/// The pane that the sidebar selects. The sidebar and the detail view share it.
final class SettingsSelection: ObservableObject {
    static let general = "general"
    @Published var id = SettingsSelection.general
}

/// The Settings sidebar: text only, like System Settings.
struct SettingsSidebar: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        List(selection: $selection.id) {
            Text("General").tag(SettingsSelection.general)
            Section {
                ForEach(registry.features, id: \.id) { feature in
                    Text(feature.title)
                        .foregroundStyle(registry.isOn(feature) ? .primary : .secondary)
                        .tag(feature.id)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The selected pane: a grouped form.
struct SettingsDetail: View {
    @ObservedObject var registry: FeatureRegistry
    @ObservedObject var selection: SettingsSelection
    /// Sets the window title to the name of the selected pane.
    let setTitle: (String) -> Void

    var body: some View {
        Group {
            if let feature = registry.features.first(where: { $0.id == selection.id }) {
                FeaturePane(registry: registry, feature: feature)
                    .id(feature.id)
            } else {
                GeneralPane(registry: registry)
            }
        }
        .onChange(of: selection.id, initial: true) { _, id in
            setTitle(registry.features.first { $0.id == id }?.title ?? "General")
        }
    }
}

/// The same header for every feature: the title, the summary, and the on/off switch.
private struct FeaturePane: View {
    @ObservedObject var registry: FeatureRegistry
    let feature: ToolsetFeature

    var body: some View {
        let on = registry.isOn(feature)
        Form {
            Section {
                Toggle(isOn: Binding(get: { on }, set: { registry.setOn(feature, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.headline)
                        Text(feature.summary).foregroundStyle(.secondary)
                    }
                }
                if feature.needsAccessibility && !registry.isTrusted {
                    Text("Waits for the Accessibility permission. See General.")
                        .foregroundStyle(.secondary)
                }
            }
            feature.makeSettingsSections()
                .disabled(!on)
        }
        .formStyle(.grouped)
    }
}

private struct GeneralPane: View {
    @ObservedObject var registry: FeatureRegistry
    @State private var startsAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Start at Login", isOn: $startsAtLogin)
                    .onChange(of: startsAtLogin) { _, on in
                        LoginItem.set(on)
                        startsAtLogin = LoginItem.isEnabled
                    }
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: registry.isTrusted ? "Allowed" : "Not allowed")
                if !registry.isTrusted {
                    Button("Open Accessibility Settings…") { AX.openAccessibilitySettings() }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .formStyle(.grouped)
    }
}
