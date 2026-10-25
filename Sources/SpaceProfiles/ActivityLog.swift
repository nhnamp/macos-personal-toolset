// Keeps the last activity lines for the settings pane and appends them to
// ~/Library/Logs/Toolset/Space Profiles.log.

import Foundation

enum Log {
    static let didChange = Notification.Name("SpaceProfilesLogDidChange")

    /// The most recent lines, newest last. Read on the main thread only.
    private(set) static var recent: [String] = []

    private static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Toolset/Space Profiles.log")

    /// Can be called from any thread.
    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)"
        DispatchQueue.main.async {
            recent.append(line)
            if recent.count > 8 { recent.removeFirst(recent.count - 8) }
            appendToFile(line)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static func appendToFile(_ line: String) {
        let manager = FileManager.default
        // Keep the file small: start again when it is bigger than 256 KB.
        if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 256_000 {
            try? manager.removeItem(at: fileURL)
        }
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
