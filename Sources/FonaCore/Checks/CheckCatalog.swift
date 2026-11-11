import Foundation

/// One check catalogue, two callers (PLAN §9): `swift test` runs it, the in-app self-test runs it.
/// Every check is a pure function against the production configuration – no server, no network.
public struct Check: Sendable {
    public let id: String
    public let area: String
    let run: @Sendable () -> String?  // nil = passed, else what went wrong

    public func execute() -> CheckResult { CheckResult(id: id, area: area, failure: run()) }
}

public struct CheckResult: Sendable {
    public let id: String
    public let area: String
    public let failure: String?
    public var passed: Bool { failure == nil }
}

/// Resolver that answers from a table – lets the catalogue simulate DNS rebinding and mixed answers.
struct TableResolver: Resolver {
    let table: [String: [String]]
    func resolve(_ host: String) -> [IPAddress] { (table[host] ?? []).compactMap(IPAddress.init) }
}

public enum CheckCatalog {
    public static var all: [Check] { attacks + parsing }

    public static func runAll() -> [CheckResult] { all.map { $0.execute() } }

    // MARK: attacks (PLAN §9.1 point 1) – every single one must be refused

    static func refuse(_ id: String, _ url: String, _ cls: RequestClass = .stream, _ expected: Rejection? = nil) -> Check {
        Check(id: id, area: "attack") {
            switch URLPolicy.check(url, cls) {
            case .success(let u): return "accepted \(u.text)"
            case .failure(let r): return expected == nil || r == expected ? nil : "refused, but as \(r.code)"
            }
        }
    }

    static func refuseAddresses(_ id: String, _ host: String, _ ips: [String]) -> Check {
        Check(id: id, area: "attack") {
            let addrs = TableResolver(table: [host: ips]).resolve(host)
            if case .success(let ip) = AddressPolicy.choose(addrs) { return "would connect to \(ip)" }
            return nil
        }
    }

    static func refuseRedirect(_ id: String, from: String, to: String, _ cls: RequestClass, chain: Int = 1) -> Check {
        Check(id: id, area: "attack") {
            guard case .success(let start) = URLPolicy.check(from, cls) else { return "start URL refused" }
            let visited = (0..<chain).map { "https://hop\($0).example.com/" }
            if case .success(let u) = URLPolicy.redirect(from: start, location: to, cls, visited: visited) { return "followed to \(u.text)" }
            return nil
        }
    }

    static func refuseHead(_ id: String, _ raw: String, _ cls: RequestClass = .stream) -> Check {
        Check(id: id, area: "attack") {
            guard let parsed = HeadParser.parse(Data(raw.utf8)) else { return "parser waits for more" }
            switch parsed {
            case .failure: return nil
            case .success(let h): if case .success(let k) = HeadParser.check(h, cls) { return "accepted as \(k)" }
            }
            return nil
        }
    }

    static func refuseBytes(_ id: String, _ data: Data) -> Check {
        Check(id: id, area: "attack") {
            switch Sniffer.sniff(data) {
            case .success(let k)?: return "taken for \(k)"
            default: return nil
            }
        }
    }

    static var attacks: [Check] {
        var c: [Check] = [
            refuse("scheme-file", "file:///etc/passwd", .stream, .scheme("file")),
            refuse("scheme-javascript", "javascript:alert(1)"),
            refuse("scheme-data", "data:audio/mpeg;base64,AAAA"),
            refuse("scheme-ftp", "ftp://example.com/a.mp3"),
            refuse("scheme-custom", "fona://play"),
            refuse("credentials", "http://user:pass@example.com/s.mp3", .stream, .credentialsInURL),
            refuse("url-too-long", "https://example.com/" + String(repeating: "a", count: 2100), .stream, .urlTooLong),
            refuse("localhost", "http://localhost/"),
            refuse("localhost-dot", "http://localhost./"),
            refuse("dot-local", "http://router.local/"),
            refuse("home-arpa", "http://nas.home.arpa/"),
            refuse("single-label", "http://router/"),
            refuse("v4-loopback", "http://127.0.0.1/"),
            refuse("v4-short", "http://127.1/"),
            refuse("v4-octal", "http://0177.0.0.1/"),
            refuse("v4-hex", "http://0x7f000001/"),
            refuse("v4-decimal", "http://2130706433/"),
            refuse("v4-trailing-dot", "http://127.0.0.1./"),
            refuse("v4-percent", "http://%31%32%37.0.0.1/"),
            refuse("v4-fullwidth", "http://１２７.０.０.１/"),
            refuse("v4-private-10", "http://10.0.0.1/"),
            refuse("v4-private-192", "http://192.168.1.1/"),
            refuse("v4-private-172", "http://172.16.5.4/"),
            refuse("v4-cgnat", "http://100.64.0.1/"),
            refuse("v4-linklocal", "http://169.254.169.254/"),
            refuse("v4-benchmark-fakeip", "http://198.18.0.1/"),
            refuse("v4-zero", "http://0.0.0.0/"),
            refuse("v4-broadcast", "http://255.255.255.255/"),
            refuse("v6-loopback", "http://[::1]/"),
            refuse("v6-compat", "http://[::127.0.0.1]/"),
            refuse("v6-mapped", "http://[::ffff:192.168.1.1]/"),
            refuse("v6-nat64", "http://[64:ff9b::c0a8:101]/"),
            refuse("v6-6to4", "http://[2002:c0a8:101::]/"),
            refuse("v6-teredo", "http://[2001:0::1]/"),
            refuse("v6-ula", "http://[fd00::1]/"),
            refuse("v6-linklocal", "http://[fe80::1]/"),
            refuse("v6-zone", "http://[fe80::1%25en0]/"),
            refuse("directory-http", "http://de1.api.radio-browser.info/json/countries", .directory),
            refuse("directory-foreign-host", "https://evil.example.com/json", .directory, .hostNotAllowed),
            refuse("update-foreign-host", "https://evil.example.com/Fona.zip", .update, .hostNotAllowed),
            refuse("report-http", "http://mountpoint-reports.moritz-poth.workers.dev/report", .report),
            refuseAddresses("dns-rebinding-private", "radio.example.com", ["192.168.1.10"]),
            refuseAddresses("dns-mixed-answer", "radio.example.com", ["93.184.216.34", "10.0.0.5"]),
            refuseAddresses("dns-v6-ula", "radio.example.com", ["fd12:3456::1"]),
            refuseAddresses("dns-mapped", "radio.example.com", ["::ffff:127.0.0.1"]),
            refuseAddresses("dns-empty", "radio.example.com", []),
            refuseRedirect("redirect-to-file", from: "https://radio.example.com/", to: "file:///etc/passwd", .stream),
            refuseRedirect("redirect-to-lan", from: "https://radio.example.com/", to: "http://192.168.1.1/", .stream),
            refuseRedirect("redirect-to-localhost", from: "https://radio.example.com/", to: "http://localhost:8080/", .stream),
            refuseRedirect("redirect-too-many", from: "https://radio.example.com/", to: "https://radio.example.com/next", .stream, chain: 6),
            refuseRedirect("redirect-loop", from: "https://hop0.example.com/", to: "https://hop0.example.com/", .stream),
            refuseRedirect("redirect-downgrade-directory", from: "https://de1.api.radio-browser.info/json/x", to: "http://de1.api.radio-browser.info/json/x", .directory),
            refuseRedirect("redirect-update-foreign", from: "https://api.github.com/x", to: "https://evil.example.com/Fona.zip", .update),
            refuseHead("html-as-audio", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"),
            refuseHead("image", "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n"),
            refuseHead("program", "HTTP/1.1 200 OK\r\nContent-Type: application/x-mach-binary\r\n\r\n"),
            refuseHead("zip-as-stream", "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\n\r\n"),
            refuseHead("ogg", "HTTP/1.1 200 OK\r\nContent-Type: application/ogg\r\n\r\n"),
            refuseHead("gzip", "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Encoding: gzip\r\n\r\n"),
            refuseHead("brotli", "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Encoding: br\r\n\r\n"),
            refuseHead("transfer-gzip", "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"),
            refuseHead("playlist-too-big", "HTTP/1.1 200 OK\r\nContent-Type: audio/x-mpegurl\r\nContent-Length: 10485760\r\n\r\n", .playlist),
            refuseHead("double-length", "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\n", .segment),
            refuseHead("http2-status", "HTTP/2 200\r\n\r\n"),
            refuseHead("error-status", "HTTP/1.1 500 Internal Server Error\r\n\r\n"),
            refuseHead("json-as-stream", "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"),
            refuseBytes("html-bytes", Data(("<!doctype html><html>" + String(repeating: "x", count: 20000)).utf8)),
            refuseBytes("macho-bytes", Data([0xCF, 0xFA, 0xED, 0xFE] + [UInt8](repeating: 0, count: 20000))),
            refuseBytes("random-bytes", randomBytes(20000, seed: 7)),
            refuseBytes("single-fake-sync", Data([UInt8](repeating: 0x00, count: 100) + [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0x00, count: 20000))),
            refuseBytes("huge-id3", Data([0x49, 0x44, 0x33, 4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F] + [UInt8](repeating: 0, count: 20000))),
            Check(id: "header-too-long", area: "attack") {
                let raw = Data(("HTTP/1.1 200 OK\r\nX: " + String(repeating: "a", count: 20000)).utf8)
                if case .failure(.headerTooLong)? = HeadParser.parse(raw) { return nil }
                return "not refused"
            },
            Check(id: "chunk-size-huge", area: "attack") {
                var d = ChunkedDecoder()
                do { _ = try d.feed(Data("FFFFFFFFF\r\n".utf8)); return "accepted" } catch { return nil }
            },
            Check(id: "chunk-negative", area: "attack") {
                var d = ChunkedDecoder()
                do { _ = try d.feed(Data("-5\r\nhello\r\n".utf8)); return "accepted" } catch { return nil }
            },
            Check(id: "chunk-plus-sign", area: "attack") {
                var d = ChunkedDecoder()
                do { _ = try d.feed(Data("+5\r\nhello\r\n".utf8)); return "accepted" } catch { return nil }
            },
            Check(id: "chunk-garbage", area: "attack") {
                var d = ChunkedDecoder()
                do { _ = try d.feed(Data("zz\r\nhello\r\n".utf8)); return "accepted" } catch { return nil }
            },
            Check(id: "negative-content-length", area: "attack") {
                guard case .success(let h)? = HeadParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\n".utf8)) else { return nil }
                return h.contentLength == nil ? nil : "took \(h.contentLength!)"
            },
            Check(id: "negative-metaint", area: "attack") {
                guard case .success(let h)? = HeadParser.parse(Data("ICY 200 OK\r\nicy-metaint: -1\r\n\r\n".utf8)) else { return nil }
                return h.icyMetaInt == nil ? nil : "took \(h.icyMetaInt!)"
            },
            Check(id: "icy-metaint-zero", area: "attack") { IcyDemuxer(metaInt: 0) == nil ? nil : "accepted" },
            Check(id: "icy-metaint-huge", area: "attack") { IcyDemuxer(metaInt: 1_000_000_000) == nil ? nil : "accepted" },
        ]
        // every message exists in both languages
        c.append(Check(id: "messages-complete", area: "attack") {
            for r in Rejection.allExamples where Messages.text(r, .de).isEmpty || Messages.text(r, .en).isEmpty { return "no text for \(r.code)" }
            return nil
        })
        return c
    }

    // MARK: parsing works on real-world shapes (must be accepted)

    static var parsing: [Check] {
        [
            Check(id: "accept-public-stream", area: "parse") {
                if case .success = URLPolicy.check("http://mp3.ffh.de/radioffh/hqlivestream.mp3", .stream) { return nil }
                return "refused"
            },
            Check(id: "accept-v4-literal-public", area: "parse") {
                if case .success = URLPolicy.check("http://195.245.217.140:8080/;.mp3", .stream) { return nil }
                return "refused"
            },
            Check(id: "accept-v6-public", area: "parse") {
                if case .success = URLPolicy.check("http://[2a00:1450:4001:80b::200e]/s", .stream) { return nil }
                return "refused"
            },
            Check(id: "accept-redirect-relative", area: "parse") {
                guard case .success(let s) = URLPolicy.check("https://radio.example.com/a/b", .stream),
                      case .success(let n) = URLPolicy.redirect(from: s, location: "/live.mp3", .stream, visited: [s.text]) else { return "refused" }
                return n.text == "https://radio.example.com/live.mp3" ? nil : "wrong target \(n.text)"
            },
            Check(id: "accept-icy-v1", area: "parse") {
                guard case .success(let h)? = HeadParser.parse(Data("ICY 200 OK\r\nicy-metaint: 8192\r\ncontent-type: audio/mpeg\r\n\r\n".utf8)) else { return "refused" }
                return h.isICY && h.icyMetaInt == 8192 ? nil : "fields wrong"
            },
            Check(id: "accept-lf-only-header", area: "parse") {
                guard case .success(let h)? = HeadParser.parse(Data("HTTP/1.1 200 OK\nContent-Type: audio/mpeg\n\n".utf8)) else { return "refused" }
                return h.value("content-type") == "audio/mpeg" ? nil : "fields wrong"
            },
            Check(id: "accept-ts-as-video", area: "parse") {
                guard case .success(let h)? = HeadParser.parse(Data("HTTP/1.1 200 OK\r\nContent-Type: video/MP2T\r\n\r\n".utf8)),
                      case .success(.mpegTS) = HeadParser.check(h, .segment) else { return "refused" }
                return nil
            },
            Check(id: "chunked-roundtrip", area: "parse") {
                var d = ChunkedDecoder()
                let out = (try? d.feed(Data("5\r\nhello\r\n6;x=1\r\n world\r\n0\r\n\r\n".utf8))) ?? Data()
                return String(decoding: out, as: UTF8.self) == "hello world" && d.finished ? nil : "got \(String(decoding: out, as: UTF8.self))"
            },
            Check(id: "chunked-split", area: "parse") {
                var d = ChunkedDecoder(), out = Data()
                for ch in "5\r\nhel" + "lo\r\n0\r\n\r\n" { out += (try? d.feed(Data(String(ch).utf8))) ?? Data() }
                return String(decoding: out, as: UTF8.self) == "hello" && d.finished ? nil : "got \(String(decoding: out, as: UTF8.self))"
            },
            Check(id: "icy-title-with-semicolon", area: "parse") {
                let title = "Wie wichtig ist Land? Leon Merfort; PIK, Britta Fecke"
                var block = [UInt8]("StreamTitle='\(title)';json='{}';".utf8)
                let len = (block.count + 15) / 16
                block += [UInt8](repeating: 0, count: len * 16 - block.count)
                var icy = IcyDemuxer(metaInt: 4)!
                let (audio, titles) = icy.feed(Data([1, 2, 3, 4, UInt8(len)] + block + [5, 6]))
                return titles == [title] && audio == Data([1, 2, 3, 4, 5, 6]) ? nil : "titles \(titles) audio \(audio.count)"
            },
            Check(id: "sniff-mp3", area: "parse") { Sniffer.sniff(TestMedia.mp3Frames(5)) == .success(.mp3) ? nil : "not mp3" },
            Check(id: "sniff-adts", area: "parse") { Sniffer.sniff(TestMedia.adtsFrames(5)) == .success(.adts) ? nil : "not adts" },
            Check(id: "sniff-mp3-after-id3", area: "parse") {
                Sniffer.sniff(TestMedia.id3(200) + TestMedia.mp3Frames(5)) == .success(.mp3) ? nil : "not mp3"
            },
            Check(id: "sniff-mp3-mid-frame", area: "parse") {
                Sniffer.sniff(Data(repeating: 0x55, count: 300) + TestMedia.mp3Frames(5)) == .success(.mp3) ? nil : "not mp3"
            },
            Check(id: "sniff-ts", area: "parse") { Sniffer.sniff(TestMedia.tsPackets(8)) == .success(.mpegTS) ? nil : "not ts" },
            Check(id: "sniff-hls", area: "parse") {
                Sniffer.sniff(Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4,\nseg.ts\n".utf8)) == .success(.hlsPlaylist) ? nil : "not hls"
            },
            Check(id: "sniff-pls", area: "parse") {
                Sniffer.sniff(Data("[playlist]\nFile1=http://a.example.com/s\n".utf8)) == .success(.plsPlaylist) ? nil : "not pls"
            },
        ]
    }

    static func randomBytes(_ n: Int, seed: UInt64) -> Data {
        var x = seed, out = [UInt8]()
        out.reserveCapacity(n)
        for _ in 0..<n { x = x &* 6364136223846793005 &+ 1442695040888963407; out.append(UInt8(x >> 56)) }
        return Data(out)
    }
}

/// Synthetic media for checks (PLAN §12: own test media, nothing copyrighted).
public enum TestMedia {
    /// MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, no padding → 417-byte frames (payload zero).
    public static func mp3Frames(_ n: Int) -> Data {
        var d = Data()
        for _ in 0..<n { d += [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 413) }
        return d
    }
    /// ADTS AAC-LC, 48 kHz (index 3), stereo, 200-byte frames.
    public static func adtsFrames(_ n: Int) -> Data {
        let len = 200
        let header: [UInt8] = [0xFF, 0xF1, 0x4C, 0x80 | UInt8((len >> 11) & 0x03), UInt8((len >> 3) & 0xFF), UInt8((len & 0x07) << 5) | 0x1F, 0xFC]
        var d = Data()
        for _ in 0..<n { d += header + [UInt8](repeating: 0, count: len - 7) }
        return d
    }
    public static func id3(_ size: Int) -> Data {
        Data([0x49, 0x44, 0x33, 4, 0, 0, UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F), UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]
             + [UInt8](repeating: 0, count: size))
    }
    public static func tsPackets(_ n: Int) -> Data {
        var d = Data()
        for _ in 0..<n { d += [0x47, 0x1F, 0xFF, 0x10] + [UInt8](repeating: 0xFF, count: 184) }
        return d
    }
}
