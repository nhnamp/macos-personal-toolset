import AppKit
import ToolsetCore

/// The icon beside each title in the switcher.
///
/// For a browser, the icon is the favicon of the website in the window. For other apps, it is the app icon.
/// The switcher reads the URL of the window through Accessibility. This step is the same for all browsers.
/// Then it reads the favicon of that page from the favicon file of the browser (see `FaviconSources`).
/// It makes no network request, and it reads only the favicon of the window's current page.
final class WindowIcons {
    /// A browser writes a new favicon to its file some seconds after the page loads.
    /// A page without a favicon in the file is checked again after this time.
    private static let missRetryInterval: TimeInterval = 30
    /// The cache is cleared at this size, so it does not grow during a long session.
    private static let maxCachedPages = 500

    private let queue = DispatchQueue(label: "WindowSwitcher.windowIcons", qos: .userInitiated)
    /// Favicons and misses per browser data folder and page URL. Read and written on `queue` only.
    private var faviconsByPage: [String: NSImage] = [:]
    private var missesByPage: [String: Date] = [:]
    /// The last favicon of each browser window. Read and written on the main thread only.
    private var lastFavicons: [CGWindowID: NSImage] = [:]

    /// True when the app is a browser with a favicon file that Toolset knows.
    static func hasFavicons(_ app: NSRunningApplication) -> Bool {
        FaviconSources.source(for: app) != nil
    }

    /// The icons to show at once: the last known favicon of a browser window, else the app icon.
    /// Without read access (Full Disk Access off), no favicon from before is shown.
    func immediateIcons(for windows: [SwitcherWindow], of app: NSRunningApplication) -> [NSImage?] {
        let canShowFavicons = FaviconSources.source(for: app).map { !$0.needsDataAccess } ?? false
        return windows.map { window in
            (canShowFavicons ? window.windowId.flatMap { lastFavicons[$0] } : nil) ?? app.icon
        }
    }

    /// Finds the favicons of browser windows on a background queue. Calls `completion` on the main thread
    /// with one entry for each window: the favicon, or nil if the window shows no website with a known favicon.
    func loadFavicons(for windows: [SwitcherWindow], of app: NSRunningApplication, completion: @escaping ([NSImage?]) -> Void) {
        let source = FaviconSources.source(for: app)
        queue.async {
            // Full Disk Access can be turned off while Toolset runs. Then the cache must not keep the old favicons.
            let canRead = source.map { !$0.needsDataAccess } ?? false
            if !canRead {
                self.faviconsByPage.removeAll()
                self.missesByPage.removeAll()
            }
            let favicons = windows.map { window -> NSImage? in
                guard canRead, let source, let url = Self.pageURL(of: window.element) else { return nil }
                return self.favicon(for: url, from: source)
            }
            DispatchQueue.main.async {
                for (window, favicon) in zip(windows, favicons) {
                    if let id = window.windowId { self.lastFavicons[id] = favicon }
                }
                completion(favicons)
            }
        }
    }

    /// Finds the URL of the page in the window. The sources come in this order:
    /// 1. The `AXDocument` attribute of the window. Chromium browsers give the full URL there.
    /// 2. The `AXURL` attribute of the web area. Safari gives the full URL there.
    /// 3. The text of the address bar: the text field in the toolbar. It can hide the scheme or the path.
    /// The search does not go into the web page content.
    static func pageURL(of window: AXUIElement) -> URL? {
        if let url = AX.string(window, kAXDocumentAttribute).flatMap(websiteURL) {
            return url
        }
        var pending: [(element: AXUIElement, isInToolbar: Bool)] = [(window, false)]
        var addressBarURL: URL?
        var index = 0
        // A browser window has about 30 elements outside the web page. The limit stops the search in a strange window.
        while index < pending.count, index < 300 {
            let (element, isInToolbar) = pending[index]
            index += 1
            let role = AX.string(element, kAXRoleAttribute)
            if role == "AXWebArea" {
                if let url = (AX.copyValue(element, "AXURL") as? URL).flatMap({ websiteURL(from: $0.absoluteString) }) {
                    return url
                }
                continue
            }
            if isInToolbar, role == kAXTextFieldRole, addressBarURL == nil {
                addressBarURL = AX.string(element, kAXValueAttribute).flatMap(websiteURL)
            }
            for child in AX.elements(element, kAXChildrenAttribute) {
                pending.append((child, isInToolbar || role == kAXToolbarRole))
            }
        }
        return addressBarURL
    }

    /// Returns the URL if it is a website. An address bar can hide `https://`, so a value without a scheme gets it.
    /// Search text (with spaces) and pages like `edge://settings` give nil.
    static func websiteURL(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" "),
              let url = URL(string: text.contains("://") ? text : "https://" + text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private func favicon(for url: URL, from source: FaviconSource) -> NSImage? {
        let page = url.absoluteString
        let key = source.dataDirectory.path + "\n" + page
        if let favicon = faviconsByPage[key] { return favicon }
        if let missTime = missesByPage[key], Date().timeIntervalSince(missTime) < Self.missRetryInterval { return nil }
        if faviconsByPage.count + missesByPage.count > Self.maxCachedPages {
            faviconsByPage.removeAll()
            missesByPage.removeAll()
        }
        let favicon = source.faviconData(page: page, host: url.host?.lowercased() ?? "").flatMap(NSImage.init(data:))
        if let favicon { faviconsByPage[key] = favicon } else { missesByPage[key] = Date() }
        return favicon
    }
}
