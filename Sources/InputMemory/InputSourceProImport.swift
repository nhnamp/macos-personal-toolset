import Foundation
import SQLite3

/// Reads the per-app rules and the default source of Input Source Pro, so the user does not type them again.
public enum InputSourceProImport {
    public struct Result {
        public var rules: [AppRule]
        public var defaultSourceID: String?
    }

    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Input Source Pro/Main.sqlite")

    public static var isAvailable: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    public static func read() -> Result? {
        guard isAvailable else { return nil }
        let known = Set(InputSources.selectable().map(\.id))
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let query = "SELECT ZBUNDLEID, ZBUNDLENAME, ZINPUTSOURCEID FROM ZAPPRULE WHERE ZINPUTSOURCEID IS NOT NULL AND IFNULL(ZREMOVED, 0) = 0"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var rules: [AppRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bundleID = text(statement, 0), let stored = text(statement, 2),
                  let sourceID = resolve(stored, known: known) else { continue }
            let name = (text(statement, 1) ?? bundleID).replacingOccurrences(of: ".app", with: "")
            rules.append(AppRule(bundleID: bundleID, appName: name, sourceID: sourceID))
        }
        let defaultID = UserDefaults(suiteName: "com.runjuu.Input-Source-Pro")?.string(forKey: "systemWideDefaultKeyboardId")
        return Result(rules: rules, defaultSourceID: defaultID.flatMap { resolve($0, known: known) })
    }

    /// Input Source Pro stores an input mode as "<source ID>::<mode ID>". Keeps the part that macOS can select.
    private static func resolve(_ stored: String, known: Set<String>) -> String? {
        stored.components(separatedBy: "::").first { known.contains($0) }
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
