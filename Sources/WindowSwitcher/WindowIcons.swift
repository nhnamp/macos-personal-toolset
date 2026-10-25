import AppKit
import ToolsetCore
import SQLite3

/// The icon beside each title in the switcher.
///
/// For Microsoft Edge, the icon is the favicon of the website in the window. For other apps, it is the app icon.
/// The switcher reads the URL from the address bar of the Edge window through Accessibility. Then it reads the favicon
/// of that page from the `Favicons` SQLite file that Edge keeps in each profile folder.
/// It makes no network request, and it reads only the favicon of the window's current page.
final class WindowIcons {
    static let edgeBundleId = "com.microsoft.edgemac"

    /// The Edge data folder. Set `TOOLSET_EDGE_DATA_DIR` to use an Edge instance that runs with its own `--user-data-dir`.
    private static let edgeDataDirectory: URL = {
        if let path = ProcessInfo.processInfo.environment["TOOLSET_EDGE_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Microsoft Edge")
    }()

    /// Edge writes a new favicon to its file some seconds after the page loads.
    /// A page without a favicon in the file is checked again after this time.
    private static let missRetryInterval: TimeInterval = 30
    /// The cache is cleared at this size, so it does not grow during a long session.
    private static let maxCachedPages = 500

    private let queue = DispatchQueue(label: "WindowSwitcher.windowIcons", qos: .userInitiated)
    /// Favicons and misses per page URL. Read and written on `queue` only.
    private var faviconsByPage: [String: NSImage] = [:]
    private var missesByPage: [String: Date] = [:]
    private var didLogReadError = false
    /// The last favicon of each Edge window. Read and written on the main thread only.
    private var lastFavicons: [CGWindowID: NSImage] = [:]

    static func isEdge(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == edgeBundleId
    }

    /// True when the Edge data folder exists but macOS does not let Toolset read it.
    /// macOS protects the folder as app data and shows no prompt for it. Full Disk Access is the remaining way to read it.
    static var needsEdgeDataAccess: Bool {
        FileManager.default.fileExists(atPath: edgeDataDirectory.path)
            && (try? FileManager.default.contentsOfDirectory(atPath: edgeDataDirectory.path)) == nil
    }

    /// The icons to show at once: the last known favicon of an Edge window, else the app icon.
    /// Without read access (Full Disk Access off), no favicon from before is shown.
    func immediateIcons(for windows: [SwitcherWindow], of app: NSRunningApplication) -> [NSImage?] {
        let canShowFavicons = Self.isEdge(app) && !Self.needsEdgeDataAccess
        return windows.map { window in
            (canShowFavicons ? window.windowId.flatMap { lastFavicons[$0] } : nil) ?? app.icon
        }
    }

    /// Finds the favicons of Edge windows on a background queue. Calls `completion` on the main thread
    /// with one entry for each window: the favicon, or nil if the window shows no website with a known favicon.
    func loadFavicons(for windows: [SwitcherWindow], completion: @escaping ([NSImage?]) -> Void) {
        queue.async {
            // Full Disk Access can be turned off while Toolset runs. Then the cache must not keep the old favicons.
            let canRead = !Self.needsEdgeDataAccess
            if !canRead {
                self.faviconsByPage.removeAll()
                self.missesByPage.removeAll()
            }
            let favicons = windows.map { window in
                canRead ? Self.addressBarURL(of: window.element).flatMap(self.favicon) : nil
            }
            DispatchQueue.main.async {
                for (window, favicon) in zip(windows, favicons) {
                    if let id = window.windowId { self.lastFavicons[id] = favicon }
                }
                completion(favicons)
            }
        }
    }

    /// Finds the address bar: the text field in the toolbar of the window. The search skips the web page content.
    private static func addressBarURL(of window: AXUIElement) -> URL? {
        var pending: [(element: AXUIElement, isInToolbar: Bool)] = [(window, false)]
        var index = 0
        // An Edge window has about 30 elements outside the web page. The limit stops the search in a strange window.
        while index < pending.count, index < 300 {
            let (element, isInToolbar) = pending[index]
            index += 1
            let role = AX.string(element, kAXRoleAttribute)
            if role == "AXWebArea" { continue }
            if isInToolbar, role == kAXTextFieldRole {
                return AX.string(element, kAXValueAttribute).flatMap(websiteURL)
            }
            for child in AX.elements(element, kAXChildrenAttribute) {
                pending.append((child, isInToolbar || role == kAXToolbarRole))
            }
        }
        return nil
    }

    /// Returns the URL in the address bar if it is a website. Edge can hide `https://`, so a value without a scheme gets it.
    /// Search text (with spaces) and pages like `edge://settings` give nil.
    static func websiteURL(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" "),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func favicon(for url: URL) -> NSImage? {
        let page = url.absoluteString
        if let favicon = faviconsByPage[page] { return favicon }
        if let missTime = missesByPage[page], Date().timeIntervalSince(missTime) < Self.missRetryInterval { return nil }
        if faviconsByPage.count + missesByPage.count > Self.maxCachedPages {
            faviconsByPage.removeAll()
            missesByPage.removeAll()
        }
        let favicon = readFavicon(page: page, host: url.host?.lowercased() ?? "")
        if let favicon { faviconsByPage[page] = favicon } else { missesByPage[page] = Date() }
        return favicon
    }

    private func readFavicon(page: String, host: String) -> NSImage? {
        for database in faviconDatabases() {
            if let data = Self.query(database, page: page, host: host), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// The `Favicons` file of each profile: `Default` first, then `Profile 1`, `Profile 2`, and the others.
    private func faviconDatabases() -> [URL] {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: Self.edgeDataDirectory, includingPropertiesForKeys: nil)
        } catch {
            if !didLogReadError {
                NSLog("Window Switcher: cannot read the Edge data folder, so Edge windows show the app icon. "
                      + "Give Toolset Full Disk Access to show website icons. \(error.localizedDescription)")
                didLogReadError = true
            }
            return []
        }
        let databases = folders.map { $0.appendingPathComponent("Favicons") }
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
        // Edge holds a lock on the file while it runs. `immutable=1` reads the file without locks.
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
