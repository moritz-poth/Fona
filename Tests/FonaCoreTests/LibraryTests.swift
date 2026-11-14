import Foundation
import Testing
@testable import FonaCore

func station(_ n: Int) -> Station {
    Station(source: .radiobrowser, stationuuid: "uuid-\(n)", name: "Sender \(n)", url: "https://radio\(n).example.com/live.mp3", countryCode: "DE")
}

@Test func favoritesHistoryAndPrune() {
    var lib = LibraryData()
    let a = lib.upsert(station(1)), b = lib.upsert(station(2)), c = lib.upsert(station(3))
    #expect(lib.upsert(station(1)) == a)  // same URL → same entry
    lib.addFavorite(a); lib.addFavorite(b)
    lib.played(c); lib.played(a); lib.played(c)
    #expect(lib.history.map(\.id) == [c, a])                 // newest first, no duplicates
    #expect(lib.historyStations.map(\.id) == [c])            // favourites are not repeated under "recently played"
    lib.moveFavorites(from: [1], to: 0)
    #expect(lib.favorites == [b, a])
    lib.removeFavorite(b)
    #expect(lib.station(b) == nil)                           // neither favourite nor history → gone
    lib.rename(a, to: "Mein\u{202E}Sender")
    #expect(lib.station(a)?.displayName == "MeinSender")
    lib.rename(a, to: "")
    #expect(lib.station(a)?.customName == nil)
}

@Test func historyIsCapped() {
    var lib = LibraryData()
    for i in 0..<25 { lib.played(lib.upsert(station(i))) }
    #expect(lib.history.count == LibraryData.maxHistory)
    #expect(lib.stations.count == LibraryData.maxHistory)
}

@Test func loadRefusesHostileFiles() throws {
    var lib = LibraryData()
    lib.addFavorite(lib.upsert(station(1)))
    #expect(LibraryData.load(lib.encoded()) == lib)
    let bad = [
        String(decoding: lib.encoded(), as: UTF8.self).replacingOccurrences(of: "https://radio1.example.com/live.mp3", with: "file:///etc/passwd"),
        String(decoding: lib.encoded(), as: UTF8.self).replacingOccurrences(of: "radio1.example.com", with: "192.168.1.1"),
        String(decoding: lib.encoded(), as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 9"),
        String(decoding: lib.encoded(), as: UTF8.self).replacingOccurrences(of: "Sender 1", with: "Sender\\u202E1"),
        "not json",
    ]
    for (i, b) in bad.enumerated() { #expect(LibraryData.load(Data(b.utf8)) == nil, "accepted bad[\(i)]") }
}

@Test func storeRoundTripAndBrokenFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fona-lib-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LibraryStore(directory: dir)
    #expect(store.load().1 == .fresh)
    var lib = LibraryData()
    lib.addFavorite(lib.upsert(station(1)))
    store.save(lib)
    store.save(lib)  // second save replaces atomically
    #expect(store.load() == (lib, .loaded))
    try Data("garbage".utf8).write(to: store.file)
    #expect(store.load().1 == .brokenReset)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("library.broken.json").path))
}

@Test func radioBrowserParsingFiltersHostileEntries() {
    let json = """
    [{"stationuuid":"9617a958-0601-11e8-ae97-52543be04c81","name":"radio\\u202Eeins","url":"https://www.radioeins.de/live.pls","url_resolved":"","countrycode":"DE","tags":"pop,rock","bitrate":128,"codec":"MP3","clickcount":500,"homepage":"javascript:alert(1)","favicon":"http://192.168.1.1/x.png"},
     {"stationuuid":"aaaa","name":"Router","url":"http://192.168.1.1/stream","countrycode":"DE","codec":"MP3","clickcount":9},
     {"stationuuid":"bbbb","name":"Ogg Radio","url":"https://ogg.example.com/s","codec":"OGG","clickcount":3},
     {"stationuuid":"not a uuid!","name":"X","url":"https://x.example.com/s","codec":"MP3"},
     {"stationuuid":"cccc","name":"","url":"https://y.example.com/s","codec":"AAC"}]
    """
    let r = RadioBrowser.parseStations(Data(json.utf8))
    #expect(r.count == 1)
    #expect(r.first?.name == "radioeins")
    #expect(r.first?.url == "https://www.radioeins.de/live.pls")
    #expect(RadioBrowser.parseStations(Data("{\"x\":1}".utf8)).isEmpty)
    let countries = RadioBrowser.parseCountries(Data(#"[{"name":"Germany","iso_3166_1":"DE","stationcount":5000},{"iso_3166_1":"de","stationcount":3},{"iso_3166_1":"<b>","stationcount":1}]"#.utf8))
    #expect(countries == [RadioBrowser.Country(code: "DE", stations: 5000)])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FONA_LIVE"] == "1"))
func liveRadioBrowserSearch() async throws {
    let rb = RadioBrowser()
    let r = try await rb.search("jazz", countries: ["DE", "AT"])
    #expect(r.count > 5)
    #expect(r.allSatisfy { $0.countryCode == "DE" || $0.countryCode == "AT" })
    let c = try await rb.countries()
    #expect(c.contains { $0.code == "DE" })
}

@Test func alphaMergeShowsNothingOutOfOrder() {
    func r(_ n: String) -> RadioBrowser.Result { .init(stationuuid: n, name: n, url: "https://x/\(n)", countryCode: nil, tags: "", bitrate: 0, codec: "", clickcount: 0) }
    var m = AlphaMerge(countries: ["DE", "AT"])
    m.add("DE", [r("Alpha"), r("Delta")], more: true)
    #expect(m.shown.isEmpty)                         // AT has not answered yet
    m.add("AT", [r("bravo"), r("Zulu")], more: false)
    #expect(m.shown.map(\.name) == ["Alpha", "bravo", "Delta"])  // Zulu waits for DE's next page
    #expect(m.hungry == ["DE"] && m.offset["DE"] == RadioBrowser.browsePage)
    m.add("DE", [r("Echo")], more: false)
    #expect(m.shown.map(\.name) == ["Alpha", "bravo", "Delta", "Echo", "Zulu"] && m.finished)
    #expect(AlphaMerge(countries: []).keys == [""])
}

@Test func musicSearchReadsArtistAndTitle() {
    let want = MusicSearch.Track(artist: "Isabel van Gelder", title: "Heartless")
    #expect(MusicSearch.track("\"Heartless\" von Isabel van Gelder") == want)   // DLF Kultur style
    #expect(MusicSearch.track("„Heartless“ by Isabel van Gelder") == want)
    #expect(MusicSearch.track("Isabel van Gelder - Heartless") == want)
    #expect(MusicSearch.track("Isabel van Gelder – Heartless")?.query == "Isabel van Gelder - Heartless")
    #expect(MusicSearch.track("Jay-Z - 99 Problems")?.artist == "Jay-Z")              // hyphen without spaces stays
    for none in ["", "radioeins", "Die Sendung mit Musik", " - ", "radioeins - Live", "x - https://evil.example"] {
        #expect(MusicSearch.track(none, station: "radioeins") == nil, "\(none)")
    }
}

@Test func musicSearchKeepsHostileTitlesInsideTheQuery() {
    let t = MusicSearch.track("AC/DC - Back?In&Black#x/../@evil.com\u{202E}")!
    for s in MusicSearch.allCases {
        let web = s.webURL(t, german: true)!
        #expect(web.scheme == "https" && web.host?.contains("evil") == false)
        #expect(!web.absoluteString.contains("&Black") && !web.absoluteString.contains("#") && !web.absoluteString.contains("/../"))
    }
    #expect(MusicSearch.spotify.appURL(MusicSearch.track("Nils Frahm - Says")!)?.absoluteString == "spotify:search:Nils%20Frahm%20-%20Says")
    #expect(MusicSearch.appleMusic.appURL(t) == nil)
}
