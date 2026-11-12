import Foundation
import SwiftUI
import ServiceManagement
import Combine
import FonaCore
import os

let log = Logger(subsystem: "io.github.moritz-poth.fona", category: "app")

/// Settings (PLAN §3.2). UserDefaults can be changed from outside (`defaults write`), so every read is checked.
@MainActor
final class AppSettings: ObservableObject {
    enum Schedule: String, CaseIterable { case hourly, hourlyAndHalf }
    enum Language: String, CaseIterable { case system, de, en }
    let d = UserDefaults.standard

    @Published var newsEnabled: Bool { didSet { d.set(newsEnabled, forKey: "newsEnabled") } }
    @Published var newsSchedule: Schedule { didSet { d.set(newsSchedule.rawValue, forKey: "newsSchedule") } }
    @Published var newsMaxMinutes: Int { didSet { d.set(newsMaxMinutes, forKey: "newsMaxMinutes") } }
    @Published var countries: [String] { didSet { d.set(countries, forKey: "countries") } }
    @Published var resumeOnLaunch: Bool { didSet { d.set(resumeOnLaunch, forKey: "resumeOnLaunch") } }
    @Published var autoUpdateCheck: Bool { didSet { d.set(autoUpdateCheck, forKey: "autoUpdateCheck") } }
    @Published var language: Language { didSet { d.set(language.rawValue, forKey: "language"); applyLanguage() } }
    @Published var lastStationID: UUID? { didSet { d.set(lastStationID?.uuidString, forKey: "lastStationID") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { launchAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { log.error("login item: \(error.localizedDescription, privacy: .public)") }
        }
    }

    init() {
        newsEnabled = d.object(forKey: "newsEnabled") as? Bool ?? true
        newsSchedule = (d.string(forKey: "newsSchedule")).flatMap(Schedule.init(rawValue:)) ?? .hourlyAndHalf  // DLF: half hours from 04:30
        let m = d.object(forKey: "newsMaxMinutes") as? Int ?? 10  // bulletins last 5–10 min (measured 2026-11-12)
        newsMaxMinutes = (3...10).contains(m) ? m : 10
        let region = Locale.current.region?.identifier
        let saved = (d.array(forKey: "countries") as? [String])?.filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isUppercase } }
        countries = Array((saved ?? [region ?? "DE"]).prefix(20))
        resumeOnLaunch = d.object(forKey: "resumeOnLaunch") as? Bool ?? false
        autoUpdateCheck = d.object(forKey: "autoUpdateCheck") as? Bool ?? true
        language = d.string(forKey: "language").flatMap(Language.init(rawValue:)) ?? .system
        lastStationID = d.string(forKey: "lastStationID").flatMap(UUID.init(uuidString:))
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applyLanguage()
    }

    func applyLanguage() {
        switch language {
        case .de: L.language = .de
        case .en: L.language = .en
        case .system: L.language = (Locale.preferredLanguages.first ?? "en").hasPrefix("de") ? .de : .en
        }
        objectWillChange.send()
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Tab { case favorites, all }

    let settings = AppSettings()
    let store = LibraryStore(directory: LibraryStore.defaultDirectory)
    let player = Player()
    let directory = RadioBrowser()
    lazy var station = StationPlayer(ring: player.program) { DecoderClient() }
    lazy var news = NewsWatcher(player: player) { DecoderClient() }

    @Published var library = LibraryData()
    @Published var notice: String?
    @Published var tab = Tab.favorites
    @Published var current: Station?
    @Published var state: StationPlayer.State = .stopped
    @Published var title = ""
    @Published var newsActive = false
    var settingsObserver: AnyCancellable?

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var results: [RadioBrowser.Result] = []
    @Published var searching = false
    @Published var searchError: String?
    var searchTask: Task<Void, Never>?

    @Published var addSheet = false
    @Published var renaming: Station?
    @Published var toast: String?

    init() {
        let (lib, result) = Snapshot.requested ? (LibraryData(), .fresh) : store.load()
        library = lib
        if result == .brokenReset { notice = L.t(.libraryReset) }
        if Snapshot.requested { DispatchQueue.main.async { Snapshot.run(self) }; return }
        try? player.start()
        station.onState = { [weak self] s in Task { @MainActor in self?.show(s) } }
        station.onTitle = { [weak self] t in Task { @MainActor in self?.title = t } }
        news.onActive = { [weak self] on in self?.newsActive = on }
        news.log = { log.notice("\($0, privacy: .public)") }
        applyNewsSettings()
        news.setEnabled(settings.newsEnabled)
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyNewsSettings() }
        }
        if CommandLine.arguments.contains("--mute") { player.volume = 0 }
        if settings.resumeOnLaunch, let id = settings.lastStationID, let s = library.station(id) { play(s) }
        // developer launch argument: --play-url <url> (checks without clicking)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--play-url"), i + 1 < args.count {
            // developer check: plays without touching the library or settings
            current = Station(source: .custom, stationuuid: nil, name: "Test", url: args[i + 1], countryCode: nil)
            station.play(args[i + 1])
        }
    }

    var isPlaying: Bool { state == .playing || state == .buffering || state == .connecting || { if case .reconnecting = state { return true }; return false }() }

    // MARK: playback

    func play(_ s: Station) {
        let id = library.upsert(s)
        library.played(id)
        save()
        current = library.station(id) ?? s
        settings.lastStationID = id
        title = ""
        player.setPlaying(false)
        station.play(s.url)
        log.notice("play \(s.source == .custom ? "custom" : "directory", privacy: .public) station")
    }

    func togglePlay() {
        if isPlaying { stop() } else if let c = current { play(c) }
    }

    func stop() {
        station.stop()
        player.setPlaying(false)
        state = .stopped
        title = ""
        news.program(playing: false, url: nil)
    }

    func show(_ s: StationPlayer.State) {
        state = s
        news.program(playing: s == .playing, url: current?.url)
        switch s {
        case .playing: player.setPlaying(true)
        case .failed(let r): player.setPlaying(false); log.error("stream failed: \(r.code, privacy: .public)")
        default: break
        }
    }

    var statusLine: String {
        switch state {
        case .connecting: return L.t(.connecting)
        case .buffering: return L.t(.buffering)
        case .reconnecting(let n): return L.f(.reconnecting, n, StationPlayer.defaultRetryDelays.count)
        case .failed(let r): return Messages.text(r, L.language)
        case .playing, .stopped: return title
        }
    }

    // MARK: library

    func save() { if !Snapshot.requested { store.save(library) } }

    func toggleFavorite(_ s: Station) {
        let id = library.upsert(s)
        library.isFavorite(id) ? library.removeFavorite(id) : library.addFavorite(id)
        save()
    }

    func isFavorite(url: String) -> Bool { library.stations.contains { $0.url == url && library.isFavorite($0.id) } }

    func moveFavorites(_ from: IndexSet, _ to: Int) { library.moveFavorites(from: from, to: to); save() }
    func remove(_ s: Station) { library.removeFavorite(s.id); library.history.removeAll { $0.id == s.id }; library.removeFavorite(s.id); save() }
    func rename(_ s: Station, _ name: String) { library.rename(s.id, to: name); save(); if current?.id == s.id { current = library.station(s.id) } }

    // MARK: directory search (≥ 2 characters, 300 ms debounce)

    func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; searchError = nil; searching = false; return }
        let countries = settings.countries
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.searching = true
            do {
                let r = try await self.directory.search(q, countries: countries)
                guard !Task.isCancelled else { return }
                self.results = r; self.searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []; self.searchError = L.t(.noDirectory)
            }
            self.searching = false
        }
    }

    // MARK: own link (S7: full probe before saving)

    enum ProbeResult: Equatable { case ok(String), refused(String) }

    func probe(_ url: String) async -> ProbeResult {
        do {
            var format: FrameGuard.Format?
            var frames = 0
            var hasTitle = false
            let deadline = Date().addingTimeInterval(10)
            let decoder = DecoderClient()
            defer { decoder.close() }
            for try await e in try await StreamSource.open(url) {
                switch e {
                case .format(let f): format = f; _ = decoder.open(f)
                case .title: hasTitle = true
                case .frames(let d):
                    guard decoder.decode(d) != nil else { return .refused(Messages.text(.notAudio, L.language)) }
                    frames += 1
                case .discontinuity, .bufferHint: break
                }
                if frames >= 20 || Date() > deadline { break }
            }
            guard let format, frames > 0 else { return .refused(Messages.text(.notAudio, L.language)) }
            var desc = format == .mp3 ? "MP3" : "AAC"
            if hasTitle { desc += L.language == .de ? " · sendet Titel" : " · sends titles" }
            return .ok(desc)
        } catch let r as Rejection {
            return .refused(Messages.text(r, L.language))
        } catch {
            return .refused(Messages.text(.network, L.language))
        }
    }

    func addCustom(url: String, name: String, favorite: Bool) {
        guard case .success(let checked) = URLPolicy.check(url, .stream) else { return }
        let clean = Sanitize.display(name)
        let s = Station(source: .custom, stationuuid: nil, name: clean.isEmpty ? checked.host : String(clean.prefix(120)),
                        url: checked.text, countryCode: nil)
        let id = library.upsert(s)
        if favorite { library.addFavorite(id) } else { library.played(id) }
        save()
    }

    // MARK: support

    func runSelfTest() {
        let results = CheckCatalog.runAll()
        let failed = results.filter { !$0.passed }
        for f in failed { log.error("self-test failed: \(f.id, privacy: .public)") }
        showToast(failed.isEmpty ? L.f(.selfTestPassed, results.count) : L.f(.selfTestFailed, failed.count, results.count))
    }

    func showToast(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if self.toast == text { self.toast = nil } }
    }

    // MARK: news

    func applyNewsSettings() {
        news.configure(halfHours: settings.newsSchedule == .hourlyAndHalf, maxMinutes: settings.newsMaxMinutes)
        news.setEnabled(settings.newsEnabled)
    }

    func backFromNews() { news.backNow() }

    var nextNewsTime: String {
        let cal = Calendar.current
        let now = Date()
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        let half = settings.newsSchedule == .hourlyAndHalf
        if half, (c.minute ?? 0) < 30 { c.minute = 30 } else { c.minute = 0; c.hour = (c.hour ?? 0) + 1 }
        let next = cal.date(from: c) ?? now
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: next)
    }
}
