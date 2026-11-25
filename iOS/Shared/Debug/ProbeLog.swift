#if DEBUG || PROBE
import Foundation

/// A small line log in the App Group container that the app and the extension both append
/// to, for checking what an extension can reach. Debug builds only. It keeps the last
/// ``maxLines`` lines and must never hold an address, MAC or speaker identifier.
enum ProbeLog {
    static let maxLines = 200

    static var url: URL? {
        AppGroup.containerURL?.appendingPathComponent("Debug", isDirectory: true).appendingPathComponent("probe.log")
    }

    static func append(_ line: String) {
        guard let url else { return }
        coordinate(url) { url in
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var lines = read(url)
            lines.append(line.replacingOccurrences(of: "\n", with: " "))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        }
    }

    /// Every line, oldest first.
    static func lines() -> [String] {
        guard let url else { return [] }
        var result: [String] = []
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &error) { url in result = read(url) }
        return result
    }

    static func clear() {
        guard let url else { return }
        coordinate(url) { url in try? FileManager.default.removeItem(at: url) }
    }

    private static func read(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Serializes writers across the app and the extension.
    private static func coordinate(_ url: URL, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: body)
    }
}
#endif
