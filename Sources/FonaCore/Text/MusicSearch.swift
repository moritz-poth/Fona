import Foundation

/// "Find this song" links (user 2026-11-14). The title comes from the station (hostile): sanitized, split into
/// artist and track, cut to 150 characters, percent-encoded except letters, digits and "-", and only ever placed into these
/// fixed hosts and schemes. A service opens in its app only where the app's search link was checked
/// (scripts/test-music-search.sh); otherwise its website.
public enum MusicSearch: String, CaseIterable, Sendable {
    case spotify = "Spotify", appleMusic = "Apple Music", youtubeMusic = "YouTube Music", amazonMusic = "Amazon Music"
    case deezer = "Deezer", tidal = "TIDAL", qobuz = "Qobuz", soundcloud = "SoundCloud"

    public struct Track: Equatable, Sendable {
        public let artist: String, title: String
        /// What the services are searched for: "Artist - Title" (user 2026-11-14).
        public var query: String { String("\(artist) - \(title)".prefix(150)) }
    }

    static let quotes = "\"'„“”«»‚‘’"

    /// Artist and track from the stream title, or nil when the title does not name both (then no search).
    /// Formats: `Artist - Title` (ICY convention, also – and —) and `"Title" von|by Artist` (e.g. DLF Kultur).
    public static func track(_ raw: String, station: String? = nil) -> Track? {
        let s = Sanitize.display(raw).trimmingCharacters(in: .whitespaces)
        var artist = "", title = ""
        if let q = s.first, quotes.contains(q),
           let close = s.dropFirst().firstIndex(where: { quotes.contains($0) }) {
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            for sep in ["von ", "by ", "- ", "– ", "— "] where rest.lowercased().hasPrefix(sep) {
                title = String(s[s.index(after: s.startIndex)..<close]); artist = String(rest.dropFirst(sep.count))
                break
            }
        }
        if title.isEmpty, let r = s.range(of: #"\s[-–—]\s"#, options: .regularExpression) {
            artist = String(s[..<r.lowerBound]); title = String(s[r.upperBound...])
        }
        let clean = { (x: String) in x.trimmingCharacters(in: CharacterSet(charactersIn: quotes).union(.whitespaces)) }
        artist = clean(artist); title = clean(title)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        if let st = station?.lowercased(), [artist.lowercased(), title.lowercased()].contains(st) { return nil }
        if (artist + title).lowercased().contains("http") { return nil }
        return Track(artist: artist, title: title)
    }

    /// Bundle id of the desktop app, for the services whose app search link is verified.
    public var appBundleID: String? {
        switch self {
        case .spotify: return "com.spotify.client"
        default: return nil
        }
    }

    static func encoded(_ t: Track) -> String { t.query.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? "" }

    public func appURL(_ t: Track) -> URL? {
        switch self {
        case .spotify: return URL(string: "spotify:search:\(Self.encoded(t))")
        default: return nil
        }
    }

    public func webURL(_ t: Track, german: Bool) -> URL? {
        let q = Self.encoded(t)
        switch self {
        case .spotify: return URL(string: "https://open.spotify.com/search/\(q)")
        case .appleMusic: return URL(string: "https://music.apple.com/\(german ? "de" : "us")/search?term=\(q)")
        case .youtubeMusic: return URL(string: "https://music.youtube.com/search?q=\(q)")
        case .amazonMusic: return URL(string: "https://music.amazon.\(german ? "de" : "com")/search/\(q)")
        case .deezer: return URL(string: "https://www.deezer.com/search/\(q)")
        case .tidal: return URL(string: "https://listen.tidal.com/search?q=\(q)")
        case .qobuz: return URL(string: "https://play.qobuz.com/search?q=\(q)")
        case .soundcloud: return URL(string: "https://soundcloud.com/search?q=\(q)")
        }
    }
}
