import AppKit
import ApplicationServices
import ToolsetCore

/// The list of features and the on/off state of each one.
/// A new feature is one more entry in the `features` array of `AppDelegate`.
final class FeatureRegistry: ObservableObject {
    let features: [ToolsetFeature]
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    private var permissionTimer: Timer?
    private var running: Set<String> = []

    init(features: [ToolsetFeature]) {
        self.features = features
    }

    func isOn(_ feature: ToolsetFeature) -> Bool {
        UserDefaults.standard.object(forKey: key(feature)) as? Bool ?? true
    }

    func setOn(_ feature: ToolsetFeature, _ on: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(on, forKey: key(feature))
        on ? startIfAllowed(feature) : stop(feature)
    }

    /// Starts the features that are on. The features that need Accessibility start when the permission is there.
    func startAll() {
        features.filter(isOn).forEach(startIfAllowed)
        guard !isTrusted, features.contains(where: \.needsAccessibility) else { return }
        permissionTimer = AX.whenTrusted { [weak self] in
            guard let self else { return }
            self.isTrusted = true
            self.features.filter(self.isOn).forEach(self.startIfAllowed)
        }
    }

    private func startIfAllowed(_ feature: ToolsetFeature) {
        guard !running.contains(feature.id), !feature.needsAccessibility || isTrusted else { return }
        running.insert(feature.id)
        feature.start()
    }

    private func stop(_ feature: ToolsetFeature) {
        guard running.remove(feature.id) != nil else { return }
        feature.stop()
    }

    private func key(_ feature: ToolsetFeature) -> String {
        "Toolset.enabled.\(feature.id)"
    }
}
