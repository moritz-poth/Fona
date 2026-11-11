import Foundation

/// N8: the bytes decide what a response really is. Looks at the first 16 KB (ICY metadata already removed),
/// skips one ID3 tag (≤ 64 KB) and demands three consecutive valid frames with matching lengths.
public enum Sniffer {
    public enum Kind: Equatable, Sendable { case mp3, adts, mpegTS, hlsPlaylist, plsPlaylist, m3uPlaylist }

    public static func sniff(_ data: Data) -> Result<Kind, Rejection>? {
        var b = [UInt8](data.prefix(Limits.maxID3Bytes + Limits.sniffBytes))
        if let text = playlistKind(b) { return .success(text) }
        if b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {  // "ID3"
            let s6: Int = Int(b[6] & 0x7F) << 21, s7: Int = Int(b[7] & 0x7F) << 14
            let s8: Int = Int(b[8] & 0x7F) << 7, s9: Int = Int(b[9] & 0x7F)
            let footer: Int = b[5] & 0x10 != 0 ? 10 : 0
            let total = 10 + (s6 | s7 | s8 | s9) + footer
            guard total <= Limits.maxID3Bytes else { return .failure(.notAudio) }
            guard b.count > total else { return nil }
            b = Array(b[total...])
        }
        b = Array(b.prefix(Limits.sniffBytes))
        if isTS(b) { return .success(.mpegTS) }
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 {
                if let k = threeFrames(b, at: i) { return .success(k) }
            }
            i += 1
        }
        return b.count >= Limits.sniffBytes ? .failure(.notAudio) : nil
    }

    static func playlistKind(_ b: [UInt8]) -> Kind? {
        var s = b.prefix(64)
        if s.starts(with: [0xEF, 0xBB, 0xBF]) { s = s.dropFirst(3) }  // UTF-8 BOM
        let head = String(decoding: s, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if head.hasPrefix("#extm3u") {
            let text = String(decoding: b.prefix(4096), as: UTF8.self)
            return text.contains("#EXT-X-") ? .hlsPlaylist : .m3uPlaylist
        }
        if head.hasPrefix("[playlist]") { return .plsPlaylist }
        return nil
    }

    static func isTS(_ b: [UInt8]) -> Bool {
        guard let start = b.prefix(188).firstIndex(of: 0x47), start + 4 * 188 < b.count else { return false }
        return (0..<5).allSatisfy { b[start + $0 * 188] == 0x47 }
    }

    static func threeFrames(_ b: [UInt8], at start: Int) -> Kind? {
        var pos = start
        var kind: Kind?
        for _ in 0..<3 {
            guard pos + 7 <= b.count else { return nil }
            if let len = adtsLength(b, pos), kind != .mp3 { kind = .adts; pos += len }
            else if let len = mp3Length(b, pos), kind != .adts { kind = .mp3; pos += len }
            else { return nil }
        }
        return kind
    }

    /// ADTS header: sync 0xFFF, layer 00, profile LC (HE-AAC is signalled as LC), rate index < 12,
    /// 1–2 channels, frame length 7…8192.
    static func adtsLength(_ b: [UInt8], _ p: Int) -> Int? {
        guard b[p] == 0xFF, b[p + 1] & 0xF6 == 0xF0 else { return nil }
        let profile = b[p + 2] >> 6, rate = (b[p + 2] >> 2) & 0x0F
        let channels = (b[p + 2] & 0x01) << 2 | b[p + 3] >> 6
        let len = Int(b[p + 3] & 0x03) << 11 | Int(b[p + 4]) << 3 | Int(b[p + 5]) >> 5
        guard profile == 1, rate < 12, (1...2).contains(channels), (7...8192).contains(len) else { return nil }
        return len
    }

    static let mp3Kbps1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let mp3Kbps2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    /// MPEG audio Layer III only, valid bitrate and sample-rate indices.
    static func mp3Length(_ b: [UInt8], _ p: Int) -> Int? {
        guard b[p] == 0xFF, b[p + 1] & 0xE0 == 0xE0 else { return nil }
        let version = (b[p + 1] >> 3) & 0x03, layer = (b[p + 1] >> 1) & 0x03
        let brIdx = Int(b[p + 2] >> 4), srIdx = Int((b[p + 2] >> 2) & 0x03), pad = Int((b[p + 2] >> 1) & 0x01)
        guard version != 1, layer == 1, (1...14).contains(brIdx), srIdx < 3 else { return nil }
        let rates: [[Int]] = [[11025, 12000, 8000], [], [22050, 24000, 16000], [44100, 48000, 32000]]
        let sr = rates[Int(version)][srIdx]
        let kbps = version == 3 ? mp3Kbps1[brIdx] : mp3Kbps2[brIdx]
        let len = (version == 3 ? 144 : 72) * kbps * 1000 / sr + pad
        return len >= 24 ? len : nil
    }
}
