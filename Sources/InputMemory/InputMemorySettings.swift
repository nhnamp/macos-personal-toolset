import Foundation

/// The input source that new windows of one app start with.
public struct AppRule: Codable, Hashable, Identifiable {
    public var bundleID: String
    public var appName: String
    public var sourceID: String
    public var id: String { bundleID }
}

/// The saved settings. The memory of each window stays in RAM only:
/// window IDs end when the app quits, so there is nothing to keep across launches.
public final class InputMemorySettings: ObservableObject {
    private struct Stored: Codable {
        var defaultSourceID: String?
        var rules: [AppRule] = []
    }

    /// The source for a new window when its app has no rule and no window yet. Nil keeps the current source.
    @Published public var defaultSourceID: String? { didSet { save() } }
    @Published public var rules: [AppRule] { didSet { save() } }

    private let defaults: UserDefaults
    private let key = "InputMemory"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        defaultSourceID = stored.defaultSourceID
        rules = stored.rules
    }

    public func rule(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        return rules.first { $0.bundleID == bundleID }?.sourceID
    }

    /// Adds or replaces the rule of an app. Keeps the list sorted by app name.
    public func setRule(_ rule: AppRule) {
        var updated = rules.filter { $0.bundleID != rule.bundleID }
        updated.append(rule)
        rules = updated.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private func save() {
        let stored = Stored(defaultSourceID: defaultSourceID, rules: rules)
        defaults.set(try? JSONEncoder().encode(stored), forKey: key)
    }
}
