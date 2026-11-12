import Foundation

/// MPEG-TS → audio elementary stream (PLAN §3). Only the first audio PID of the first programme:
/// stream type 0x0F (ADTS AAC) or 0x03/0x04 (MPEG audio). LATM (0x11) and everything else is refused.
/// Every length is checked against the packet; garbage packets are skipped, never trusted.
public struct TsDemuxer: Sendable {
    public private(set) var format: FrameGuard.Format?
    var pmtPID: Int?
    var audioPID: Int?
    var pes = [UInt8]()
    var carry = [UInt8]()
    public private(set) var badPackets = 0
    public var refusedLATM = false
    /// TV streams (video in the programme) are refused: Fona is a radio, and video costs megabits for nothing.
    public private(set) var hasVideo = false

    public init() {}

    /// Returns elementary-stream bytes found so far. Throws `.notAudio` when the stream holds only LATM/unknown audio.
    public mutating func feed(_ data: Data) throws -> Data {
        var b = carry
        b.append(contentsOf: data)
        carry.removeAll()
        var out = Data()
        var i = 0
        while i + 188 <= b.count {
            guard b[i] == 0x47 else { i += 1; badPackets += 1; continue }
            try packet(b, i, &out)
            i += 188
        }
        carry = Array(b[i...])
        if carry.count > 188 * 4 { carry.removeAll() }
        if hasVideo || (refusedLATM && audioPID == nil) { throw Rejection.notAudio }
        return out
    }

    /// End of segment: flushes the last PES.
    public mutating func flush() -> Data {
        var out = Data()
        flushPES(&out)
        return out
    }

    mutating func packet(_ b: [UInt8], _ i: Int, _ out: inout Data) throws {
        let pusi = b[i + 1] & 0x40 != 0
        let pid = Int(b[i + 1] & 0x1F) << 8 | Int(b[i + 2])
        let afc = (b[i + 3] >> 4) & 0x03
        var off = i + 4
        if afc & 0x02 != 0 {
            let afLen = Int(b[off])
            off += 1 + afLen
        }
        guard afc & 0x01 != 0, off < i + 188 else { return }
        let payload = b[off..<i + 188]
        if pid == 0, pusi { parsePAT(Array(payload)) }
        else if pid == pmtPID, pusi { parsePMT(Array(payload)) }
        else if pid == audioPID {
            if pusi { flushPES(&out); pes = Array(payload) } else if !pes.isEmpty { pes.append(contentsOf: payload) }
            if pes.count > 1_048_576 { pes.removeAll(); badPackets += 1 }  // runaway PES
        }
    }

    mutating func flushPES(_ out: inout Data) {
        defer { pes.removeAll(keepingCapacity: true) }
        guard pes.count > 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }
        let hdr = 9 + Int(pes[8])
        guard hdr < pes.count else { badPackets += 1; return }
        out.append(contentsOf: pes[hdr...])
    }

    mutating func parsePAT(_ p: [UInt8]) {
        guard !p.isEmpty else { return }
        let s = 1 + Int(p[0])
        guard s + 12 <= p.count, p[s] == 0x00 else { badPackets += 1; return }
        let sectionLen = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let end = min(p.count, s + 3 + sectionLen - 4)
        var j = s + 8
        while j + 4 <= end {
            let program = Int(p[j]) << 8 | Int(p[j + 1])
            let pid = Int(p[j + 2] & 0x1F) << 8 | Int(p[j + 3])
            if program != 0 { pmtPID = pid; return }
            j += 4
        }
    }

    mutating func parsePMT(_ p: [UInt8]) {
        guard !p.isEmpty, audioPID == nil, !hasVideo else { return }
        let s = 1 + Int(p[0])
        guard s + 12 <= p.count, p[s] == 0x02 else { badPackets += 1; return }
        let sectionLen = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let progInfo = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        let end = min(p.count, s + 3 + sectionLen - 4)
        var j = s + 12 + progInfo
        while j + 5 <= end {
            let type = p[j], pid = Int(p[j + 1] & 0x1F) << 8 | Int(p[j + 2])
            let esLen = Int(p[j + 3] & 0x0F) << 8 | Int(p[j + 4])
            switch type {
            case 0x0F where audioPID == nil: audioPID = pid; format = .adts
            case 0x03, 0x04: if audioPID == nil { audioPID = pid; format = .mp3 }
            case 0x11: refusedLATM = true
            case 0x01, 0x02, 0x10, 0x1B, 0x24, 0x42, 0xEA: hasVideo = true  // MPEG-1/2, MPEG-4, H.264, HEVC, CAVS, VC-1
            default: break
            }
            j += 5 + esLen
        }
    }
}
