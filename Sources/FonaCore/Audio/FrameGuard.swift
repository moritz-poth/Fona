import Foundation

/// PLAN S5: only complete, valid MP3 Layer III / ADTS AAC frames reach Apple's decoders. Streaming: feed raw audio
/// bytes, get whole frames back. A frame is released only when the header of the following frame is valid too,
/// so a random 0xFF byte cannot start a fake frame. ID3 tags in the stream (≤ 64 KB) are skipped.
public struct FrameGuard: Sendable {
    public enum Format: Sendable { case mp3, adts }
    public let format: Format
    var buf = [UInt8]()
    var start = 0
    public private(set) var droppedBytes = 0
    var resyncRun = 0  // bytes skipped since the last good frame

    public init(format: Format) { self.format = format }

    func frameLength(_ b: [UInt8], _ p: Int) -> Int? {
        guard p + 7 <= b.count else { return nil }
        return format == .adts ? Sniffer.adtsLength(b, p) : Sniffer.mp3Length(b, p)
    }

    public mutating func feed(_ data: Data) throws -> Data {
        buf.append(contentsOf: data)
        var out = Data()
        while true {
            let left = buf.count - start
            guard left >= 10 else { break }
            if buf[start] == 0x49, buf[start + 1] == 0x44, buf[start + 2] == 0x33 {  // "ID3" inside the stream
                let size = Int(buf[start + 6] & 0x7F) << 21 | Int(buf[start + 7] & 0x7F) << 14
                    | Int(buf[start + 8] & 0x7F) << 7 | Int(buf[start + 9] & 0x7F)
                guard size <= Limits.maxID3Bytes else { throw Rejection.notAudio }
                guard left >= 10 + size else { break }
                start += 10 + size
                continue
            }
            if let len = frameLength(buf, start) {
                guard left >= len + 7 else { break }  // need the next header for confirmation
                if frameLength(buf, start + len) != nil || (buf[start + len] == 0x49 && buf[start + len + 1] == 0x44) {
                    out.append(contentsOf: buf[start..<start + len])
                    start += len
                    resyncRun = 0
                    continue
                }
            }
            start += 1  // resync byte by byte
            droppedBytes += 1
            resyncRun += 1
            if resyncRun > Limits.maxID3Bytes { throw Rejection.notAudio }
        }
        if start > 65_536 { buf.removeFirst(start); start = 0 }  // keep memory bounded
        guard buf.count - start <= Limits.maxID3Bytes + 16_384 else { throw Rejection.notAudio }
        return out
    }
}
