import Foundation

/// Append-only diagnostics file. NSLog output is not reliably visible in the
/// unified log for this app (LSUIElement, launched via `open`), which made the
/// recurring "gap above the island" impossible to investigate after the fact.
/// This writes somewhere we can always read: ~/.vibeisland/diagnostics.log
enum Diagnostics {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibeisland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()

    private static let queue = DispatchQueue(label: "vibeisland.diagnostics")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(data)
                trimIfNeeded()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Keep the file small — it runs for days.
    private static func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 256_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n").suffix(1500).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
