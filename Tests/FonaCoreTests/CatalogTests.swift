import Foundation
import Testing
@testable import FonaCore

/// The whole check catalogue – the same functions the in-app self-test runs (PLAN §9).
@Test(arguments: CheckCatalog.all.map(\.id))
func catalogue(_ id: String) {
    let check = CheckCatalog.all.first { $0.id == id }!
    let r = check.execute()
    #expect(r.passed, "\(id): \(r.failure ?? "")")
}

/// A6: no network or foreign-loading API outside NetGate; NetGate has no test or bypass modes.
@Test func noNetworkOutsideNetGate() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")
    let forbidden = ["URLSession", "NWConnection", "CFStream", "getaddrinfo", "Data(contentsOf:", "String(contentsOf:",
                     "NSImage(contentsOf:", "AsyncImage", "AVPlayer", "AVURLAsset", "WKWebView", "inputNode"]
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && !$0.path.contains("/Sources/fona-") }  // developer tools are not shipped
    #expect(!files.isEmpty)
    for f in files {
        let text = try String(contentsOf: f, encoding: .utf8)
        let inGate = f.path.contains("/NetGate/")
        for word in forbidden where text.contains(word) {
            let allowedHere = inGate && ["NWConnection", "getaddrinfo"].contains(word)
            #expect(allowedHere, "\(word) used in \(f.lastPathComponent)")
        }
        if inGate {
            for word in ["testMode", "allowLocal", "bypass", "isTesting"] {
                #expect(!text.contains(word), "NetGate must not have \(word)")
            }
        }
    }
}

/// Live checks against real stations – only with FONA_LIVE=1 (needs internet).
@Test(.enabled(if: ProcessInfo.processInfo.environment["FONA_LIVE"] == "1"),
      arguments: ["https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3",
                  "http://mp3.ffh.de/radioffh/hqlivestream.mp3",
                  "http://stream3.polskieradio.pl:8080/;.mp3"])
func liveStream(_ url: String) async throws {
    let r = try await NetGate.shared.open(url, .stream)
    var icy = r.head.icyMetaInt.flatMap(IcyDemuxer.init(metaInt:))
    var audio = Data()
    for try await piece in r.body {
        audio += icy.map { var i = $0; let a = i.feed(piece).audio; icy = i; return a } ?? piece
        if audio.count > 40_000 { r.cancel(); break }
    }
    #expect(Sniffer.sniff(audio) == .success(.mp3))
}
