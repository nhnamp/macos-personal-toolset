import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sections of the settings pane. The host puts them in a grouped `Form`.
/// Plain system controls only, so the pane follows the system look in light and dark mode.
struct InputMemorySettingsView: View {
    @ObservedObject var memory: InputMemory
    @ObservedObject var settings: InputMemorySettings
    @State private var sources: [InputSource] = InputSources.selectable()
    @State private var importNote: String?

    var body: some View {
        Group {
            Section {
                Picker("New windows start with", selection: defaultSource) {
                    Text("Keep current").tag("")
                    Divider()
                    ForEach(sources) { Text($0.name).tag($0.id) }
                }
                note("A new window uses its app's rule first, then the source of the app's other windows, then this setting.")
            }

            Section("App Rules") {
                if settings.rules.isEmpty {
                    note("No rules. New windows follow the setting above.")
                }
                ForEach(settings.rules) { rule in
                    HStack {
                        Picker(rule.appName, selection: binding(for: rule)) {
                            ForEach(sources) { Text($0.name).tag($0.id) }
                        }
                        Button("Remove") { settings.rules.removeAll { $0.bundleID == rule.bundleID } }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add App…", action: addApp)
                    if InputSourceProImport.isAvailable {
                        Button("Import from Input Source Pro", action: importFromInputSourcePro)
                    }
                    Spacer()
                    if let importNote { Text(importNote).foregroundStyle(.secondary) }
                }
            }

            Section {
                LabeledContent("Windows remembered", value: "\(memory.rememberedCount)")
                Button("Forget All Windows") { memory.forgetAll() }
                note("The memory of a window ends when its app quits or Input Memory turns off.")
            }
        }
        .onAppear {
            sources = InputSources.selectable()
            memory.pruneClosedWindows()
        }
    }

    /// Secondary text in a row of its own, aligned with the other rows.
    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private var defaultSource: Binding<String> {
        Binding(get: { settings.defaultSourceID ?? "" }, set: { settings.defaultSourceID = $0.isEmpty ? nil : $0 })
    }

    private func binding(for rule: AppRule) -> Binding<String> {
        Binding(get: { rule.sourceID }, set: { settings.setRule(AppRule(bundleID: rule.bundleID, appName: rule.appName, sourceID: $0)) })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let source = InputSources.currentID() ?? sources.first?.id ?? ""
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            settings.setRule(AppRule(bundleID: bundleID, appName: name, sourceID: source))
        }
    }

    private func importFromInputSourcePro() {
        guard let result = InputSourceProImport.read() else {
            importNote = "Could not read Input Source Pro's rules."
            return
        }
        for rule in result.rules { settings.setRule(rule) }
        if settings.defaultSourceID == nil { settings.defaultSourceID = result.defaultSourceID }
        importNote = result.rules.count == 1 ? "Imported 1 rule." : "Imported \(result.rules.count) rules."
    }
}
