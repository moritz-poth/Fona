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
    public static var all: [Check] { attacks + parsing + content + hls + news }

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

    // MARK: foreign text, playlists, frames (PLAN S1, S4, S5)

    static func sanitized(_ id: String, _ input: String, _ expected: String) -> Check {
        Check(id: id, area: "text") {
            let out = Sanitize.display(input)
            return out == expected ? nil : "got \(out.debugDescription)"
        }
    }

    static var content: [Check] {
        [
            sanitized("text-bidi-override", "Song\u{202E}3pm.exe", "Song3pm.exe"),
            sanitized("text-bidi-isolates", "a\u{2066}b\u{2069}c\u{200F}", "abc"),
            sanitized("text-zero-width", "Ra\u{200B}dio\u{FEFF}\u{2060}", "Radio"),
            sanitized("text-tag-chars", "Hi\u{E0041}\u{E007F}", "Hi"),
            sanitized("text-line-separators", "one\u{2028}two\u{2029}three\nfour\tfive", "one two three four five"),
            sanitized("text-control", "a\u{0}b\u{7}c\u{1B}[31m", "abc[31m"),
            sanitized("text-private-use", "x\u{E000}y", "xy"),
            sanitized("text-markdown-stays-text", "[click](https://evil.example)", "[click](https://evil.example)"),
            sanitized("text-nfc", "Cafe\u{301}", "Café"),
            sanitized("text-spaces", "  Nils   Frahm  –  Says  ", "Nils Frahm – Says"),
            sanitized("text-umlauts-kept", "Bühne – Café · 1LIVE", "Bühne – Café · 1LIVE"),
            Check(id: "text-zalgo", area: "text") {
                let out = Sanitize.display("Z" + String(repeating: "\u{0336}", count: 500) + "a")
                return out.unicodeScalars.count <= 4 ? nil : "\(out.unicodeScalars.count) scalars"
            },
            Check(id: "text-length", area: "text") {
                let out = Sanitize.display(String(repeating: "ä", count: 5000))
                return out.count <= 200 && out.utf8.count <= 800 ? nil : "\(out.count) graphemes"
            },
            Check(id: "playlist-pls", area: "playlist") {
                let e = PlaylistParser.entries(Data("[playlist]\nNumberOfEntries=2\nFile1=https://a.example.com/s\nTitle1=x\nFile2=http://b.example.com/t\n".utf8))
                return e == ["https://a.example.com/s", "http://b.example.com/t"] ? nil : "\(e)"
            },
            Check(id: "playlist-m3u", area: "playlist") {
                let e = PlaylistParser.entries(Data("#EXTM3U\n#EXTINF:-1,Radio\nhttp://a.example.com/s.mp3\n".utf8))
                return e == ["http://a.example.com/s.mp3"] ? nil : "\(e)"
            },
            Check(id: "playlist-no-file-scheme", area: "attack") {
                let e = PlaylistParser.entries(Data("[playlist]\nFile1=file:///etc/passwd\nFile2=javascript:x\nFile3=//evil\n".utf8))
                return e.isEmpty ? nil : "\(e)"
            },
            Check(id: "playlist-cap", area: "attack") {
                let text = (1...500).map { "File\($0)=http://h\($0).example.com/" }.joined(separator: "\n")
                let e = PlaylistParser.entries(Data(text.utf8))
                return e.count == PlaylistParser.maxEntries ? nil : "\(e.count) entries"
            },
            Check(id: "frames-pass-mp3", area: "frames") {
                var g = FrameGuard(format: .mp3)
                let out = (try? g.feed(TestMedia.mp3Frames(6))) ?? Data()
                return out.count == 5 * 417 ? nil : "\(out.count) bytes"  // last frame waits for the next header
            },
            Check(id: "frames-skip-garbage", area: "frames") {
                var g = FrameGuard(format: .adts)
                let input = Data([0xFF, 0xF1, 0x00, 0x13, 0x37]) + TestMedia.adtsFrames(4)
                let out = (try? g.feed(input)) ?? Data()
                return out.count == 3 * 200 && g.droppedBytes == 5 ? nil : "\(out.count) bytes, dropped \(g.droppedBytes)"
            },
            Check(id: "frames-skip-id3", area: "frames") {
                var g = FrameGuard(format: .mp3)
                let out = (try? g.feed(TestMedia.mp3Frames(2) + TestMedia.id3(300) + TestMedia.mp3Frames(3))) ?? Data()
                return out.count == 4 * 417 ? nil : "\(out.count) bytes"
            },
            Check(id: "frames-refuse-noise", area: "attack") {
                var g = FrameGuard(format: .mp3)
                do { _ = try g.feed(randomBytes(200_000, seed: 9)); return "accepted noise" } catch { return nil }
            },
            Check(id: "frames-refuse-huge-id3", area: "attack") {
                var g = FrameGuard(format: .mp3)
                do { _ = try g.feed(Data([0x49, 0x44, 0x33, 4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F]) + Data(count: 100)); return "accepted" } catch { return nil }
            },
            Check(id: "frames-wrong-format", area: "frames") {
                var g = FrameGuard(format: .adts)
                let out = (try? g.feed(TestMedia.mp3Frames(5))) ?? Data()
                return out.isEmpty ? nil : "mp3 accepted as adts"
            },
        ]
    }

    // MARK: HLS and MPEG-TS (PLAN S2)

    static func hlsRefused(_ id: String, _ text: String) -> Check {
        Check(id: id, area: "attack") {
            if case .success(let p) = HlsPlaylist.parse(Data(text.utf8)) { return "accepted \(p)" }
            return nil
        }
    }

    static let mediaHead = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:100\n"

    static var hls: [Check] {
        [
            hlsRefused("hls-aes", mediaHead + "#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:4,\ns1.ts\n"),
            hlsRefused("hls-sample-aes", mediaHead + "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:4,\ns1.ts\n"),
            hlsRefused("hls-session-key", "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"k\"\n#EXT-X-STREAM-INF:BANDWIDTH=128000\na.m3u8\n"),
            hlsRefused("hls-fmp4", mediaHead + "#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\ns1.m4s\n"),
            hlsRefused("hls-byterange", mediaHead + "#EXTINF:4,\n#EXT-X-BYTERANGE:999999999@0\ns1.ts\n"),
            hlsRefused("hls-target-zero", "#EXTM3U\n#EXT-X-TARGETDURATION:0\n#EXTINF:4,\ns1.ts\n"),
            hlsRefused("hls-target-huge", "#EXTM3U\n#EXT-X-TARGETDURATION:99999\n#EXTINF:4,\ns1.ts\n"),
            hlsRefused("hls-negative-duration", mediaHead + "#EXTINF:-4,\ns1.ts\n"),
            hlsRefused("hls-video-only-master", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS=\"avc1.64001f,mp4a.40.2\"\nv.m3u8\n"),
            hlsRefused("hls-not-a-playlist", "<html>hello</html>"),
            hlsRefused("hls-too-many-segments", mediaHead + String(repeating: "#EXTINF:4,\ns.ts\n", count: 10_001)),
            Check(id: "hls-key-none-ok", area: "parse") {
                if case .success(.media) = HlsPlaylist.parse(Data((mediaHead + "#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\ns1.ts\n").utf8)) { return nil }
                return "refused METHOD=NONE"
            },
            Check(id: "hls-master-choice", area: "parse") {
                let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.5\"\nlo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=102545,CODECS=\"mp4a.40.2\"\n96/seg.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200189,CODECS=\"mp4a.40.2\"\n192/seg.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS=\"avc1.4d,mp4a.40.2\"\nvideo.m3u8\n"
                guard case .success(.master(let v)) = HlsPlaylist.parse(Data(text.utf8)) else { return "not a master" }
                return v.count == 3 && HlsPlaylist.choose(v)?.uri == "96/seg.m3u8" ? nil : "chose \(HlsPlaylist.choose(v)?.uri ?? "-") of \(v.count)"
            },
            Check(id: "hls-delta-skip", area: "parse") {
                let text = mediaHead + "#EXT-X-SERVER-CONTROL:CAN-SKIP-UNTIL=24\n#EXT-X-SKIP:SKIPPED-SEGMENTS=50\n#EXTINF:4,\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:4,\nb.ts\n"
                guard case .success(.media(let m)) = HlsPlaylist.parse(Data(text.utf8)) else { return "refused" }
                return m.canSkip && m.segments.map(\.sequence) == [150, 151] && m.segments[1].discontinuity ? nil : "\(m.segments)"
            },
            Check(id: "ts-adts", area: "parse") {
                var d = TsDemuxer()
                let es = (try? d.feed(TestMedia.tsSegment(streamType: 0x0F, payload: TestMedia.adtsFrames(20)))) ?? Data()
                let all = es + d.flush()
                return d.format == .adts && all == TestMedia.adtsFrames(20) ? nil : "format \(String(describing: d.format)), \(all.count) bytes"
            },
            Check(id: "ts-refuse-latm", area: "attack") {
                var d = TsDemuxer()
                do { _ = try d.feed(TestMedia.tsSegment(streamType: 0x11, payload: Data(count: 1000))); return "accepted LATM" } catch { return nil }
            },
            Check(id: "ts-refuse-video", area: "attack") {
                var d = TsDemuxer()
                do { _ = try d.feed(TestMedia.tsSegment(streamType: 0x0F, payload: TestMedia.adtsFrames(5), extraStreamType: 0x1B)); return "accepted video" } catch { return nil }
            },
            Check(id: "ts-garbage", area: "attack") {
                var d = TsDemuxer()
                let out = (try? d.feed(randomBytes(188 * 50, seed: 11))) ?? Data()
                return out.isEmpty ? nil : "\(out.count) bytes from noise"
            },
        ]
    }

    // MARK: news switch (PLAN §9.1 point 3)

    static func detections(_ pcm: [Float]) -> [ToneDetector.Detection] {
        let d = ToneDetector()
        var out: [ToneDetector.Detection] = []
        var i = 0
        while i < pcm.count { let n = min(9600, pcm.count - i); out += d.feed(Array(pcm[i..<i + n])); i += n }
        return out
    }

    static var news: [Check] {
        [
            Check(id: "news-time-signal", area: "news") {
                let pcm = TestMedia.music(seconds: 3) + TestMedia.timeSignal() + TestMedia.music(seconds: 3)
                let d = detections(pcm)
                guard d.count == 1 else { return "\(d.count) detections" }
                let start = Double(d[0].toneStartFrame) / DecoderCore.sampleRate
                return abs(start - 3.0) < 0.15 ? nil : "first pip at \(start) s, expected 3.0"
            },
            Check(id: "news-no-false-alarm-music", area: "news") {
                detections(TestMedia.music(seconds: 30)).isEmpty ? nil : "music triggered"
            },
            Check(id: "news-no-false-alarm-noise", area: "news") {
                let noise = (0..<(48_000 * 10 * 2)).map { i in Float(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1) * 0.3 }
                return detections(noise).isEmpty ? nil : "noise triggered"
            },
            Check(id: "news-single-long-tone", area: "news") {
                let pcm = TestMedia.music(seconds: 2) + TestMedia.sine(780, seconds: 0.8) + TestMedia.music(seconds: 2)
                return detections(pcm).isEmpty ? nil : "a lone tone without pips triggered"
            },
            Check(id: "news-endless-tone", area: "news") {
                detections(TestMedia.sine(780, seconds: 10)).isEmpty ? nil : "a 10 s tone triggered"
            },
            Check(id: "news-title-rule", area: "news") {
                NewsLogic.isNewsTitle("Nachrichten") && !NewsLogic.isNewsTitle("Nachrichtenleicht") ? nil : "title rule wrong"
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
    /// One TS segment: PAT, PMT (audio PID 0x101 of `streamType`, optional second stream), PES packets with `payload`.
    public static func tsSegment(streamType: UInt8, payload: Data, extraStreamType: UInt8? = nil) -> Data {
        func packet(pid: Int, pusi: Bool, _ body: [UInt8]) -> [UInt8] {
            var p: [UInt8] = [0x47, UInt8((pusi ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF), 0x10]
            p += body.prefix(184)
            p += [UInt8](repeating: 0xFF, count: 188 - p.count)
            return p
        }
        let pat: [UInt8] = [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        var streams: [UInt8] = [streamType, 0xE1, 0x01, 0xF0, 0x00]
        if let x = extraStreamType { streams = [x, 0xE1, 0x00, 0xF0, 0x00] + streams }
        let secLen = 9 + streams.count + 4
        let pmt: [UInt8] = [0x00, 0x02, 0xB0, UInt8(secLen), 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00] + streams + [0, 0, 0, 0]
        var out = packet(pid: 0, pusi: true, pat) + packet(pid: 0x1000, pusi: true, pmt)
        let pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0, 0x00, 0x00, 0x80, 0x00, 0x00] + [UInt8](payload)
        var rest = pes[...]
        var first = true
        while !rest.isEmpty {
            // full packets only: pad the last one with an adaptation field so no 0xFF stuffing lands in the PES
            let take = min(184, rest.count)
            var p: [UInt8] = [0x47, UInt8((first ? 0x40 : 0) | 0x01), 0x01]
            if take == 184 {
                p += [0x10] + rest.prefix(184)
            } else {
                let af = 184 - take - 1
                p += [0x30, UInt8(af)] + (af > 0 ? [0x00] + [UInt8](repeating: 0xFF, count: af - 1) : []) + rest.prefix(take)
            }
            out += p
            rest = rest.dropFirst(take)
            first = false
        }
        return Data(out)
    }

    /// 48 kHz interleaved stereo sine.
    public static func sine(_ hz: Double, seconds: Double, level: Float = 0.25) -> [Float] {
        let n = Int(seconds * 48_000)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { let v = level * Float(sin(2 * .pi * hz * Double(i) / 48_000)); out[2 * i] = v; out[2 * i + 1] = v }
        return out
    }
    public static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 48_000) * 2) }
    /// Deutschlandfunk-like time signal: two short pips one second apart, then a long pip, then silence.
    public static func timeSignal() -> [Float] {
        sine(780, seconds: 0.15) + silence(0.85) + sine(780, seconds: 0.15) + silence(0.85) + sine(780, seconds: 0.8) + silence(1.5)
    }
    /// Chord with changing notes – stands in for music (contains 784 Hz G5 on purpose).
    public static func music(seconds: Double) -> [Float] {
        let notes: [[Double]] = [[261.6, 329.6, 392.0], [392.0, 493.9, 784.0], [349.2, 440.0, 523.3], [293.7, 370.0, 784.0]]
        let n = Int(seconds * 48_000)
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let chord = notes[(i / 24_000) % notes.count]
            let t = Double(i) / 48_000
            let v = Float(chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) } * 0.08)
            out[2 * i] = v; out[2 * i + 1] = v
        }
        return out
    }

    public static func tsPackets(_ n: Int) -> Data {
        var d = Data()
        for _ in 0..<n { d += [0x47, 0x1F, 0xFF, 0x10] + [UInt8](repeating: 0xFF, count: 184) }
        return d
    }
}
