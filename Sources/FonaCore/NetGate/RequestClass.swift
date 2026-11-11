import Foundation

/// What a request is for. Every rule in NetGate depends on it (PLAN §4.1, table "Anfrageklassen").
public enum RequestClass: String, CaseIterable, Sendable {
    case stream, playlist, segment, directory, update, report

    /// Plain http is only allowed for media; everything else must be https.
    public var allowsHTTP: Bool { self == .stream || self == .playlist || self == .segment }

    /// Fixed host list, or nil = any public host.
    public var allowedHosts: Set<String>? {
        switch self {
        case .stream, .playlist, .segment: return nil
        case .directory: return nil  // radio-browser mirrors come from DNS; checked by `isRadioBrowserHost`
        case .update: return ["api.github.com", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]
        case .report: return [Limits.reportHost]
        }
    }

    /// Largest body accepted, nil = endless stream.
    public var maxBody: Int? {
        switch self {
        case .stream: return nil
        case .playlist: return Limits.hlsPlaylistBytes
        case .segment: return Limits.segmentBytes
        case .directory: return Limits.directoryBytes
        case .update: return Limits.updateBytes
        case .report: return Limits.reportBytes
        }
    }

    func hostAllowed(_ host: String) -> Bool {
        if self == .directory { return Limits.isRadioBrowserHost(host) }
        return allowedHosts?.contains(host) ?? true
    }
}

/// All numeric limits in one place (PLAN §4.1 N6, §4.2).
public enum Limits {
    public static let maxURLLength = 2048
    public static let maxRedirects = 5
    public static let maxHeaderBytes = 16 * 1024
    public static let connectTimeout: TimeInterval = 10
    public static let headerTimeout: TimeInterval = 15
    public static let stallTimeout: TimeInterval = 20
    public static let throughputWindow: TimeInterval = 30
    public static let minThroughputShare = 0.25
    public static let plainPlaylistBytes = 64 * 1024
    public static let hlsPlaylistBytes = 2 * 1024 * 1024
    public static let segmentBytes = 4 * 1024 * 1024
    public static let directoryBytes = 2 * 1024 * 1024
    public static let updateBytes = 50 * 1024 * 1024
    public static let reportBytes = 256 * 1024
    public static let sniffBytes = 16 * 1024
    public static let maxID3Bytes = 64 * 1024
    public static let maxChunkSize = 8 * 1024 * 1024
    // the existing multi-app report worker (Mountpoint's); Fona gets its own `product` entry in P6
    public static let reportHost = "mountpoint-reports.moritz-poth.workers.dev"

    public static func isRadioBrowserHost(_ host: String) -> Bool {
        host == "all.api.radio-browser.info" || (host.hasSuffix(".api.radio-browser.info") && host.split(separator: ".").count == 4)
    }
}
