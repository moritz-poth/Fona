import Foundation

/// "Find this song" links (user 2026-11-14). The title comes from the station (hostile): sanitized, cut to 150
/// characters, percent-encoded as alphanumerics only, and only ever placed into these fixed hosts and schemes.
public enum MusicSearch: String, CaseIterable, Sendable {
    case spotify = "Spotify", appleMusic = "Apple Music", amazonMusic = "Amazon Music"

    /// Bundle id of the desktop app whose own URL scheme we use when it is installed (Amazon has none we can rely on).
    public var appBundleID: String? {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        case .amazonMusic: return nil
        }
    }

    /// "Artist - Song" → "Artist Song" (the dash only confuses the services' search).
    public static func query(_ title: String) -> String {
        let t = Sanitize.display(title).replacingOccurrences(of: " - ", with: " ").replacingOccurrences(of: " – ", with: " ")
        return String(t.prefix(150))
    }

    static func encoded(_ title: String) -> String? {
        let q = query(title)
        guard !q.isEmpty else { return nil }
        return q.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    public func appURL(_ title: String) -> URL? {
        guard let q = Self.encoded(title) else { return nil }
        switch self {
        case .spotify: return URL(string: "spotify:search:\(q)")
        case .appleMusic: return URL(string: "music://music.apple.com/search?term=\(q)")
        case .amazonMusic: return nil
        }
    }

    public func webURL(_ title: String, german: Bool) -> URL? {
        guard let q = Self.encoded(title) else { return nil }
        switch self {
        case .spotify: return URL(string: "https://open.spotify.com/search/\(q)")
        case .appleMusic: return URL(string: "https://music.apple.com/\(german ? "de" : "us")/search?term=\(q)")
        case .amazonMusic: return URL(string: "https://music.amazon.\(german ? "de" : "com")/search/\(q)")
        }
    }
}
