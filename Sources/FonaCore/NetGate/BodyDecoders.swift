import Foundation

/// Streaming decoder for `Transfer-Encoding: chunked`. Feed raw bytes, get body bytes; never buffers a whole chunk.
public struct ChunkedDecoder: Sendable {
    enum State: Sendable { case size, data(Int), dataEnd, trailer, done }
    var state = State.size
    var line = [UInt8]()
    public private(set) var finished = false

    public init() {}

    public mutating func feed(_ input: Data) throws -> Data {
        var out = Data()
        var i = input.startIndex
        while i < input.endIndex {
            switch state {
            case .size, .trailer, .dataEnd:
                let byte = input[i]; i += 1
                if byte == 0x0A {
                    let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
                    line.removeAll()
                    switch state {
                    case .dataEnd:
                        guard text.isEmpty else { throw Rejection.badChunk }
                        state = .size
                    case .trailer:
                        if text.isEmpty { state = .done; finished = true }
                    default:
                        let hex = text.split(separator: ";").first.map(String.init) ?? ""
                        // hex digits only: Int(_:radix:) would also take "-5" or "+5" (found by fuzzing)
                        guard !hex.isEmpty, hex.count <= 8, hex.allSatisfy(\.isHexDigit),
                              let size = Int(hex, radix: 16), size <= Limits.maxChunkSize else {
                            throw Rejection.badChunk
                        }
                        state = size == 0 ? .trailer : .data(size)
                    }
                } else {
                    line.append(byte)
                    guard line.count <= 1024 else { throw Rejection.badChunk }
                }
            case .data(let left):
                let n = min(left, input.endIndex - i)
                out.append(input[i..<i + n]); i += n
                state = left - n == 0 ? .dataEnd : .data(left - n)
            case .done:
                return out
            }
        }
        return out
    }
}

/// Removes Icecast/Shoutcast metadata blocks from a stream and reports `StreamTitle` (S3).
public struct IcyDemuxer: Sendable {
    public let metaInt: Int
    var untilMeta: Int
    var metaLeft = -1  // -1: expecting length byte when untilMeta == 0
    var meta = [UInt8]()

    public init?(metaInt: Int) {
        guard (1...65_536).contains(metaInt) else { return nil }
        self.metaInt = metaInt; untilMeta = metaInt
    }

    /// Returns (audio bytes, raw titles found). Titles are raw server text: pass through `Sanitize` before use.
    public mutating func feed(_ input: Data) -> (audio: Data, titles: [String]) {
        var audio = Data(), titles: [String] = []
        var i = input.startIndex
        while i < input.endIndex {
            if untilMeta > 0 {
                let n = min(untilMeta, input.endIndex - i)
                audio.append(input[i..<i + n]); i += n; untilMeta -= n
            } else if metaLeft < 0 {
                metaLeft = Int(input[i]) * 16; i += 1  // ≤ 255 × 16 = 4080 bytes by construction
                if metaLeft == 0 { metaLeft = -1; untilMeta = metaInt }
            } else {
                let n = min(metaLeft, input.endIndex - i)
                meta.append(contentsOf: input[i..<i + n]); i += n; metaLeft -= n
                if metaLeft == 0 {
                    if let t = Self.title(meta) { titles.append(t) }
                    meta.removeAll(); metaLeft = -1; untilMeta = metaInt
                }
            }
        }
        return (audio, titles)
    }

    /// `StreamTitle='` up to the next `';` or the end of the block (titles may contain `;` and `'`, see dlf.log).
    static func title(_ block: [UInt8]) -> String? {
        let raw = block.prefix { $0 != 0 }
        let text = String(data: Data(raw), encoding: .utf8) ?? String(data: Data(raw), encoding: .isoLatin1) ?? ""
        guard let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "';")?.lowerBound ?? (rest.hasSuffix("'") ? rest.index(before: rest.endIndex) : rest.endIndex)
        return String(rest[..<end])
    }
}
