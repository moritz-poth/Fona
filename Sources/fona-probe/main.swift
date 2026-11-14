// Developer tool: fona-probe <class> <url> – opens the URL through NetGate and prints what came back.
import Foundation
import FonaCore

let args = CommandLine.arguments
// fona-probe musicsearch "<stream title>" – the links the song search would open (scripts/test-music-search.sh)
if args.count == 3, args[1] == "musicsearch" {
    guard let t = MusicSearch.track(args[2]) else { print("NO-TRACK"); exit(1) }
    print("QUERY\t\(t.query)")
    for s in MusicSearch.allCases {
        print([s.rawValue, s.appBundleID ?? "-", s.appURL(t)?.absoluteString ?? "-", s.webURL(t, german: true)?.absoluteString ?? "-"].joined(separator: "\t"))
    }
    exit(0)
}
guard args.count == 3, let cls = RequestClass(rawValue: args[1]) else {
    print("usage: fona-probe <stream|playlist|segment|directory|update|report> <url>"); exit(2)
}
do {
    let r = try await NetGate.shared.open(args[2], cls)
    var data = Data()
    var icy = r.head.icyMetaInt.flatMap(IcyDemuxer.init(metaInt:))
    var titles: [String] = []
    for try await piece in r.body {
        if icy != nil { let (a, t) = icy!.feed(piece); data.append(a); titles += t } else { data.append(piece) }
        if data.count >= 65_536 { r.cancel(); break }
    }
    let sniff = Sniffer.sniff(data).map { String(describing: $0) } ?? "need more"
    print("OK \(r.head.isICY ? "ICY" : "HTTP") \(r.head.status) kind=\(r.kind) sniff=\(sniff) bytes=\(data.count) metaint=\(r.head.icyMetaInt ?? 0) titles=\(titles.count) url=\(r.url.host)")
} catch let e as Rejection {
    print("REJECTED \(e.code): \(Messages.text(e, .de))")
} catch {
    print("ERROR \(error)")
}
