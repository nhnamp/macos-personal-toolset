import AppKit
import CryptoKit
import SQLite3

/// A file where a browser keeps the favicons of the pages that it showed.
/// Browsers of one engine use one file format. Thus there is one reader for each engine, not for each browser.
protocol FaviconSource {
    /// The data folder of the browser. macOS protects it as app data, so the read needs Full Disk Access.
    var dataDirectory: URL { get }
    /// Returns the image data of the favicon of the page, or of another page on the same host. Runs on a background queue.
    func faviconData(page: String, host: String) -> Data?
}

extension FaviconSource {
    /// True when the data folder exists but macOS does not let Toolset read it.
    /// macOS shows no prompt for app data. Full Disk Access is the remaining way to read it.
    var needsDataAccess: Bool {
        FileManager.default.fileExists(atPath: dataDirectory.path)
            && (try? FileManager.default.contentsOfDirectory(atPath: dataDirectory.path)) == nil
    }
}

enum FaviconSources {
    /// The data folders of Chromium browsers, relative to `~/Library/Application Support`.
    /// All of them use the same `Favicons` file, so a new Chromium browser needs one line here.
    private static let chromiumFolders = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
        "org.chromium.Chromium": "Chromium",
    ]

    private static let applicationSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support")

    /// The favicon file of the app, or nil if the app is not a known browser.
    static func source(for app: NSRunningApplication) -> FaviconSource? {
        guard let bundleId = app.bundleIdentifier else { return nil }
        if let folder = chromiumDataDirectory(bundleId: bundleId) {
            return ChromiumFavicons(dataDirectory: folder)
        }
        if bundleId == SafariFavicons.bundleId {
            return SafariFavicons()
        }
        return nil
    }

    /// The favicon files of the known browsers that are on this Mac. The permission check uses them.
    static var installed: [FaviconSource] {
        let chromium: [FaviconSource] = chromiumFolders.keys.sorted()
            .compactMap(chromiumDataDirectory)
            .map(ChromiumFavicons.init)
        return (chromium + [SafariFavicons()]).filter { FileManager.default.fileExists(atPath: $0.dataDirectory.path) }
    }

    /// True when a browser data folder exists but Toolset cannot read it.
    static var needsDataAccess: Bool {
        installed.contains { $0.needsDataAccess }
    }

    /// The data folder of a known Chromium browser, or nil for other apps.
    private static func chromiumDataDirectory(bundleId: String) -> URL? {
        // `TOOLSET_EDGE_DATA_DIR` is for an Edge instance that runs with its own `--user-data-dir`.
        if bundleId == "com.microsoft.edgemac",
           let path = ProcessInfo.processInfo.environment["TOOLSET_EDGE_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return chromiumFolders[bundleId].map { applicationSupport.appendingPathComponent($0) }
    }
}

/// The `Favicons` SQLite file that Chromium browsers keep in each profile folder.
struct ChromiumFavicons: FaviconSource {
    let dataDirectory: URL

    func faviconData(page: String, host: String) -> Data? {
        for database in databases() {
            if let data = Self.query(database, page: page, host: host) { return data }
        }
        return nil
    }

    /// The `Favicons` file of each profile: `Default` first, then `Profile 1`, `Profile 2`, and the others.
    /// Opera keeps one profile in the data folder itself, so that folder is a candidate too.
    private func databases() -> [URL] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: dataDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        let databases = ([dataDirectory] + folders).map { $0.appendingPathComponent("Favicons") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        let isDefault = { (url: URL) in url.deletingLastPathComponent().lastPathComponent == "Default" }
        return databases.filter(isDefault) + databases.filter { !isDefault($0) }
    }

    /// Reads the PNG data of the favicon of the page. If the page is not in the file, it reads the favicon
    /// of another page on the same host. A host can have a different icon on each page (Google Docs and Google Sheets),
    /// so the exact page comes first.
    private static func query(_ database: URL, page: String, host: String) -> Data? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // Chromium holds a lock on the file while it runs. `immutable=1` reads the file without locks.
        guard sqlite3_open_v2(database.absoluteString + "?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else { return nil }

        // "https://host/" ≤ page_url < "https://host0" selects every page of the host, because "0" follows "/".
        // The row shows the icon at 16 pt, so a bitmap of 32 px or a little larger comes first.
        let sql = """
            SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ?1
               OR (m.page_url >= ?2 AND m.page_url < ?3)
               OR (m.page_url >= ?4 AND m.page_url < ?5)
            ORDER BY m.page_url = ?1 DESC, b.width < 32, abs(b.width - 32), b.last_updated DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (position, value) in [page, "https://\(host)/", "https://\(host)0", "http://\(host)/", "http://\(host)0"].enumerated() {
            sqlite3_bind_text(statement, Int32(position + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}

/// The favicon cache of Safari: `favicons.db` maps each page to an icon UUID, and the `favicons` folder
/// keeps the image of each icon in an ICO file. The file name is the MD5 hash of the UUID text, in uppercase hex.
struct SafariFavicons: FaviconSource {
    static let bundleId = "com.apple.Safari"

    let dataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")

    private var cacheDirectory: URL { dataDirectory.appendingPathComponent("Favicon Cache") }

    func faviconData(page: String, host: String) -> Data? {
        for iconId in iconIds(page: page, host: host) {
            let name = Insecure.MD5.hash(data: Data(iconId.utf8)).map { String(format: "%02X", $0) }.joined()
            if let data = try? Data(contentsOf: cacheDirectory.appendingPathComponent("favicons/\(name)")) {
                return data
            }
        }
        return nil
    }

    /// The icon UUIDs of the page, then of other pages on the same host. The same order as in `ChromiumFavicons`.
    private func iconIds(page: String, host: String) -> [String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // Safari writes new favicons to the `-wal` file first. `immutable=1` ignores that file, so it is not used here.
        let path = cacheDirectory.appendingPathComponent("favicons.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }

        let sql = """
            SELECT i.uuid FROM page_url p JOIN icon_info i ON i.uuid = p.uuid
            WHERE p.url = ?1
               OR (p.url >= ?2 AND p.url < ?3)
               OR (p.url >= ?4 AND p.url < ?5)
            ORDER BY p.url = ?1 DESC, i.width < 32, abs(i.width - 32), i.timestamp DESC
            LIMIT 5
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (position, value) in [page, "https://\(host)/", "https://\(host)0", "http://\(host)/", "http://\(host)0"].enumerated() {
            sqlite3_bind_text(statement, Int32(position + 1), value, -1, transient)
        }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            ids.append(String(cString: text))
        }
        return ids
    }
}
