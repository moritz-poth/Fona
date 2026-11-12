import Foundation

/// HLS playlist parsing (PLAN S2). Pure: text in, structure out. Refuses encryption, fMP4, byte ranges and
/// video-only masters; limits variants and segments.
public enum HlsPlaylist: Equatable, Sendable {
    case master([Variant])
    case media(Media)

    public struct Variant: Equatable, Sendable {
        public let uri: String
        public let bandwidth: Int
        public let codecs: String?
    }

    public struct Segment: Equatable, Sendable {
        public let sequence: Int
        public let uri: String
        public let duration: Double
        public let discontinuity: Bool
    }

    public struct Media: Equatable, Sendable {
        public let targetDuration: Double
        public let segments: [Segment]
        public let canSkip: Bool
        public let ended: Bool
    }

    public static let maxVariants = 8
    public static let maxSegments = 10_000

    public static func parse(_ data: Data) -> Result<HlsPlaylist, Rejection> {
        guard data.count <= Limits.hlsPlaylistBytes else { return .failure(.bodyTooLarge) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first, first.hasPrefix("#EXTM3U") || first.hasPrefix("\u{FEFF}#EXTM3U") else {
            return .failure(.notAudio)
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) { return parseMaster(lines) }
        return parseMedia(lines)
    }

    static func attributes(_ line: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() { if !key.isEmpty { out[key.uppercased()] = value }; key = ""; value = ""; inKey = true }
        for ch in line {
            if inKey {
                if ch == "=" { inKey = false } else if ch != "," { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return out
    }

    static func afterColon(_ line: String) -> Substring {
        line.firstIndex(of: ":").map { line[line.index(after: $0)...] } ?? ""
    }

    static func parseMaster(_ lines: [String]) -> Result<HlsPlaylist, Rejection> {
        var variants: [Variant] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-SESSION-KEY") { return .failure(.notAudio) }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pending = attributes(afterColon(line))
            } else if !line.hasPrefix("#"), !line.isEmpty, let attrs = pending {
                pending = nil
                let codecs = attrs["CODECS"]?.lowercased()
                // audio only: AAC (mp4a.40.x) or MP3 (mp4a.40.34 / mp4a.6b); anything with video or AC-3 is skipped
                if let c = codecs, !c.split(separator: ",").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("mp4a.") }) { continue }
                guard let bw = attrs["BANDWIDTH"].flatMap({ ResponseHead.digits($0) }) else { continue }
                variants.append(Variant(uri: line, bandwidth: bw, codecs: codecs))
                if variants.count == maxVariants { break }
            }
        }
        return variants.isEmpty ? .failure(.notAudio) : .success(.master(variants))
    }

    /// Lowest bandwidth ≥ 96 kbit/s, otherwise the highest available.
    public static func choose(_ variants: [Variant]) -> Variant? {
        variants.filter { $0.bandwidth >= 96_000 }.min { $0.bandwidth < $1.bandwidth } ?? variants.max { $0.bandwidth < $1.bandwidth }
    }

    static func parseMedia(_ lines: [String]) -> Result<HlsPlaylist, Rejection> {
        var target: Double?
        var sequence = 0
        var segments: [Segment] = []
        var duration: Double?
        var discontinuity = false
        var canSkip = false
        var ended = false
        for line in lines {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                guard let t = ResponseHead.digits(String(afterColon(line))), (1...30).contains(t) else { return .failure(.notAudio) }
                target = Double(t)
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let s = ResponseHead.digits(String(afterColon(line))) else { return .failure(.notAudio) }
                sequence = s
            } else if line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY") {
                let method = attributes(afterColon(line))["METHOD"]?.uppercased() ?? ""
                if method != "NONE" { return .failure(.notAudio) }  // AES-128, SAMPLE-AES: encrypted
            } else if line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-BYTERANGE") {
                return .failure(.notAudio)  // fMP4 / byte ranges: not supported
            } else if line.hasPrefix("#EXT-X-SERVER-CONTROL") {
                canSkip = attributes(afterColon(line))["CAN-SKIP-UNTIL"] != nil
            } else if line.hasPrefix("#EXT-X-SKIP:") {
                guard let n = attributes(afterColon(line))["SKIPPED-SEGMENTS"].flatMap({ ResponseHead.digits($0) }),
                      n <= maxSegments else { return .failure(.notAudio) }
                sequence += n
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY") && !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if line.hasPrefix("#EXTINF:") {
                let d = afterColon(line).split(separator: ",").first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard let d, d > 0, d <= 60 else { return .failure(.notAudio) }
                duration = d
            } else if !line.hasPrefix("#"), !line.isEmpty, let d = duration {
                segments.append(Segment(sequence: sequence, uri: line, duration: d, discontinuity: discontinuity))
                sequence += 1
                duration = nil
                discontinuity = false
                guard segments.count <= maxSegments else { return .failure(.bodyTooLarge) }
            }
        }
        guard let target, !segments.isEmpty else { return .failure(.notAudio) }
        return .success(.media(Media(targetDuration: target, segments: segments, canSkip: canSkip, ended: ended)))
    }
}
