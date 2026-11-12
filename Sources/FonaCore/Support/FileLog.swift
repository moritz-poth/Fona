import Foundation

/// Fona.log in the app's container (`~/Library/Containers/…/Data/Library/Logs/Fona/`), one line per event,
/// rotated at 1 MB to Fona.old.log (PLAN §3, A5). Lines never contain URLs, station names or titles – callers pass
/// codes and kinds only, and every line runs through `Sanitize.display` anyway. Writing never stops the app.
public final class FileLog: @unchecked Sendable {
    public static let shared = FileLog()
    public static let maxBytes = 1_000_000

    public let file: URL
    let lock = NSLock()
    var lastLine = ""
    var repeats = 0

    public init(directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Logs/Fona")) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("Fona.log")
    }

    public func write(_ event: String) {
        let text = Sanitize.display(event)
        lock.lock(); defer { lock.unlock() }
        // the same error over and over (e.g. no network) is written once per 100 repeats
        if text == lastLine { repeats += 1; if repeats % 100 != 0 { return } } else { lastLine = text; repeats = 0 }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(text)\(repeats > 0 ? " (×\(repeats))" : "")\n"
        rotateIfNeeded()
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size >= Self.maxBytes else { return }
        let old = file.deletingLastPathComponent().appendingPathComponent("Fona.old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }

    /// Last lines for a report.
    public func tail(_ n: Int = 200) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(n).map { String($0.prefix(600)) }
    }
}
