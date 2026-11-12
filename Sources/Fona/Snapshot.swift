import SwiftUI
import FonaCore

/// Developer launch argument `--snapshot`: draws every view with demo data (light + dark) into PNGs in the app's
/// temporary folder and quits. Nothing is saved to the library. Used to check the UI against design/canvas.
@MainActor
enum Snapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func run(_ model: AppModel) {
        var lib = LibraryData()
        for (n, u) in [("radioeins", "https://www.radioeins.de/live.pls"), ("Deutschlandfunk", "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3"),
                       ("FluxFM", "https://streams.fluxfm.de/live/mp3-320/audio/"), ("ByteFM", "https://bytefm.example.com/live")] {
            lib.addFavorite(lib.upsert(Station(source: .radiobrowser, stationuuid: nil, name: n, url: u, countryCode: "DE")))
        }
        for (n, u) in [("1LIVE", "https://1live.example.com/s"), ("Bayern 3", "https://b3.example.com/s"), ("NDR Blue", "https://ndrblue.example.com/s")] {
            lib.played(lib.upsert(Station(source: .radiobrowser, stationuuid: nil, name: n, url: u, countryCode: "DE")))
        }
        model.library = lib
        model.current = lib.favoriteStations.first
        model.state = .playing
        model.title = "Nils Frahm – Says"
        model.results = [("NDR Blue", "Jazz", 128), ("BR Klassik Jazz", "Jazz", 96), ("Ö1 Jazz", "Jazz", 192), ("Jazzradio Berlin", "Jazz", 128)]
            .enumerated().map { i, r in
                RadioBrowser.Result(stationuuid: "\(i)", name: r.0, url: "https://r\(i).example.com/s", countryCode: i == 2 ? "AT" : "DE",
                                    tags: r.1, bitrate: r.2, codec: "MP3", clickcount: 100 - i)
            }
        model.query = "jazz"
        model.searchTask?.cancel(); model.searching = false

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fona-snapshots")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            model.tab = .favorites; model.newsActive = false
            render(PopoverView(model: model, settings: model.settings), "1-favorites\(suffix)", out, dark, CGSize(width: 360, height: 600))
            model.newsActive = true
            render(PopoverView(model: model, settings: model.settings), "2-news\(suffix)", out, dark, CGSize(width: 360, height: 600))
            model.newsActive = false; model.tab = .all
            render(PopoverView(model: model, settings: model.settings), "3-all\(suffix)", out, dark, CGSize(width: 360, height: 600))
            model.addSheet = true
            render(PopoverView(model: model, settings: model.settings), "4-add\(suffix)", out, dark, CGSize(width: 360, height: 600))
            model.addSheet = false
            render(SettingsView(model: model, settings: model.settings), "5-settings\(suffix)", out, dark, CGSize(width: 560, height: 740))
        }
        print("snapshots: \(out.path)")
        NSApp.terminate(nil)
    }

    static func render(_ view: some View, _ name: String, _ dir: URL, _ dark: Bool, _ size: CGSize) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))  // let lists lay out
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
