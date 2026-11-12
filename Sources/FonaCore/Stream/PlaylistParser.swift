import Foundation

/// .pls and plain .m3u playlists (PLAN S1): text only, ≤ 100 entries read. Callers try at most 3, one level deep;
/// every entry goes through NetGate again.
public enum PlaylistParser {
    public static let maxEntries = 100
    public static let maxTries = 3

    public static func entries(_ data: Data) -> [String] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            var candidate: String?
            if line.lowercased().hasPrefix("file"), let eq = line.firstIndex(of: "=") {  // PLS: File1=http://…
                candidate = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            } else if !line.hasPrefix("#"), !line.hasPrefix("["), !line.contains("=") || line.contains("://") {
                candidate = line  // M3U: bare URL lines
            }
            if let c = candidate, c.lowercased().hasPrefix("http://") || c.lowercased().hasPrefix("https://") {
                out.append(c)
                if out.count == maxEntries { break }
            }
        }
        return out
    }
}
