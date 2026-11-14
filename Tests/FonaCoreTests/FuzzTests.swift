import Foundation
import Testing
@testable import FonaCore

/// PLAN §9.3: random and mutated input for every parser – no crash, no hang. Default 20 000 rounds per parser;
/// FONA_FUZZ=1 runs 1 000 000 (release check).
let fuzzRounds = ProcessInfo.processInfo.environment["FONA_FUZZ"] == "1" ? 1_000_000 : 20_000

struct Rng {
    var x: UInt64
    mutating func next() -> UInt64 { x = x &* 6364136223846793005 &+ 1442695040888963407; return x }
    mutating func int(_ n: Int) -> Int { Int(next() >> 33) % max(n, 1) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(next() >> 56) } }
    mutating func mutate(_ seed: [UInt8]) -> [UInt8] {
        var b = seed
        for _ in 0...int(8) {
            guard !b.isEmpty else { break }
            switch int(4) {
            case 0: b[int(b.count)] = UInt8(next() >> 56)
            case 1: b.insert(contentsOf: bytes(int(16)), at: int(b.count))
            case 2: let a = int(b.count); b.removeSubrange(a..<min(b.count, a + int(32)))
            default: b += b.prefix(int(64))
            }
        }
        return b
    }
}

@Test func fuzzHeadParser() {
    var r = Rng(x: 1)
    let seeds = ["HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nicy-metaint: 16000\r\n\r\n", "ICY 200 OK\nicy-br:128\n\n",
                 "HTTP/1.0 302 Found\r\nLocation: http://a.example.com/x\r\n\r\n"].map { [UInt8]($0.utf8) }
    for i in 0..<fuzzRounds {
        let input = i % 3 == 0 ? r.bytes(r.int(400)) : r.mutate(seeds[i % seeds.count])
        if case .success(let h)? = HeadParser.parse(Data(input)) {
            for cls in RequestClass.allCases { _ = HeadParser.check(h, cls) }
        }
    }
}

@Test func fuzzChunked() throws {
    var r = Rng(x: 2)
    let seed = [UInt8]("5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
    for i in 0..<fuzzRounds {
        var d = ChunkedDecoder()
        let input = i % 2 == 0 ? r.bytes(r.int(200)) : r.mutate(seed)
        var off = 0
        while off < input.count {
            let n = 1 + r.int(16)
            guard (try? d.feed(Data(input[off..<min(input.count, off + n)]))) != nil else { break }
            off += n
        }
    }
}

@Test func fuzzIcyDemuxer() {
    var r = Rng(x: 3)
    for _ in 0..<fuzzRounds / 4 {
        guard var icy = IcyDemuxer(metaInt: 1 + r.int(64)) else { continue }
        let input = r.bytes(r.int(3000))
        var off = 0
        while off < input.count {
            let n = 1 + r.int(512)
            _ = icy.feed(Data(input[off..<min(input.count, off + n)]))
            off += n
        }
    }
}

@Test func fuzzSniffer() {
    var r = Rng(x: 4)
    let seeds = [TestMedia.mp3Frames(4), TestMedia.adtsFrames(6), TestMedia.tsPackets(6), TestMedia.id3(100) + TestMedia.mp3Frames(3)].map { [UInt8]($0) }
    for i in 0..<fuzzRounds / 4 {
        let input = i % 2 == 0 ? r.bytes(r.int(4000)) : r.mutate(seeds[i % seeds.count])
        _ = Sniffer.sniff(Data(input))
    }
}

@Test func fuzzURLPolicy() {
    var r = Rng(x: 5)
    let alphabet = Array("htps:/[]@%.0123456789abcdef:-_~?#xX\u{FF11}\u{0}\n ")
    let seeds = ["http://example.com/a", "https://[2a00::1]:8080/x?y", "http://127.0.0.1/", "http://a.b.c.d.e/"]
    for i in 0..<fuzzRounds {
        var s = Array(seeds[i % seeds.count])
        for _ in 0..<r.int(6) {
            let ch = alphabet[r.int(alphabet.count)]
            if r.int(2) == 0, !s.isEmpty { s[r.int(s.count)] = ch } else { s.insert(ch, at: r.int(s.count + 1)) }
        }
        if case .success(let u) = URLPolicy.check(String(s), .stream) {
            // anything accepted must be public and re-check to itself
            if let ip = u.ipLiteral { #expect(AddressPolicy.isPublic(ip), "accepted private \(u.text)") }
            #expect(URLPolicy.check(u.text, .stream) == .success(u), "not stable: \(String(s))")
        }
    }
}

@Test func fuzzFrameGuard() {
    var r = Rng(x: 6)
    let seeds = [TestMedia.mp3Frames(8), TestMedia.adtsFrames(10), TestMedia.id3(50) + TestMedia.mp3Frames(4)].map { [UInt8]($0) }
    for i in 0..<fuzzRounds / 10 {
        var g = FrameGuard(format: i % 2 == 0 ? .mp3 : .adts)
        let input = i % 3 == 0 ? r.bytes(r.int(6000)) : r.mutate(seeds[i % seeds.count])
        var off = 0
        while off < input.count {
            let n = 1 + r.int(700)
            guard (try? g.feed(Data(input[off..<min(input.count, off + n)]))) != nil else { break }
            off += n
        }
    }
}

@Test func fuzzSanitizeAndPlaylists() {
    var r = Rng(x: 7)
    for _ in 0..<fuzzRounds / 4 {
        let bytes = r.bytes(r.int(600))
        let text = String(decoding: bytes, as: UTF8.self)
        let out = Sanitize.display(text)
        #expect(out.count <= Sanitize.maxGraphemes && out.utf8.count <= Sanitize.maxBytes)
        #expect(!out.unicodeScalars.contains { $0.properties.generalCategory == .format || $0.properties.generalCategory == .control })
        _ = PlaylistParser.entries(Data(bytes))
    }
}

@Test func fuzzMusicSearch() {
    var r = Rng(x: 11)
    let seeds = ["Isabel van Gelder - Heartless", "\"Heartless\" von Isabel van Gelder", "„A“ by B", "A — B"].map { Array($0.utf8) }
    for _ in 0..<fuzzRounds / 4 {
        let bytes = r.int(2) == 0 ? r.bytes(r.int(300)) : r.mutate(seeds[r.int(seeds.count)])
        guard let t = MusicSearch.track(String(decoding: bytes, as: UTF8.self)) else { continue }
        #expect(!t.artist.isEmpty && !t.title.isEmpty && t.query.count <= 150)
        for s in MusicSearch.allCases {
            let u = s.webURL(t, german: true)
            // the title never adds a parameter: at most the one fixed "&i=digital-music" (Amazon)
            #expect(u?.scheme == "https" && (u?.query ?? "").components(separatedBy: "&").count <= 2 && u?.fragment == nil)
        }
    }
}

@Test func fuzzHlsAndTs() {
    var r = Rng(x: 8)
    let playlists = [CheckCatalog.mediaHead + "#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=24\n#EXTINF:4,\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:4,\nb.ts\n",
                     "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=102545,CODECS=\"mp4a.40.2\"\n96/seg.m3u8\n"].map { [UInt8]($0.utf8) }
    let segs = [TestMedia.tsSegment(streamType: 0x0F, payload: TestMedia.adtsFrames(12)), TestMedia.tsSegment(streamType: 0x03, payload: TestMedia.mp3Frames(6))].map { [UInt8]($0) }
    for i in 0..<fuzzRounds / 4 {
        _ = HlsPlaylist.parse(Data(r.mutate(playlists[i % 2])))
        var d = TsDemuxer()
        let input = i % 3 == 0 ? r.bytes(r.int(4000)) : r.mutate(segs[i % 2])
        _ = try? d.feed(Data(input))
        _ = d.flush()
    }
}
