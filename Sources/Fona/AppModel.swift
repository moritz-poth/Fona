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
    @Published var betas: Bool { didSet { d.set(betas, forKey: "betas") } }
    /// Tag of the update the user skipped; hidden from automatic checks until a newer one or a manual check.
    @Published var skippedUpdate: String? { didSet { d.set(skippedUpdate, forKey: "skippedUpdate") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume"); onVolume?(volume) } }
    var onVolume: ((Double) -> Void)?
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
        betas = d.object(forKey: "betas") as? Bool ?? false
        skippedUpdate = d.string(forKey: "skippedUpdate").flatMap { $0.count <= 64 ? $0 : nil }  // only ever compared
        let v = d.object(forKey: "volume") as? Double ?? 0.8
        volume = v.isFinite && (0...1).contains(v) ? v : 0.8
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
    lazy var updater = AppUpdater(settings: settings)

    @Published var library = LibraryData()
    @Published var notice: String?
    @Published var tab = Tab.favorites
    @Published var current: Station? { didSet { if !Snapshot.requested { NowPlaying.update(self) } } }
    @Published var state: StationPlayer.State = .stopped { didSet { if !Snapshot.requested { NowPlaying.update(self) } } }
    @Published var title = "" { didSet { if !Snapshot.requested { NowPlaying.update(self) } } }
    @Published var newsActive = false
    @Published var newsSkipped = false
    var settingsObserver: AnyCancellable?

    @Published var query = "" { didSet { scheduleSearch() } }
    @Published var results: [RadioBrowser.Result] = []
    @Published var browse = AlphaMerge(countries: [])
    @Published var browseFailed = false
    var browseTask: Task<Void, Never>?
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
        NowPlaying.start(self)
        station.onState = { [weak self] s in Task { @MainActor in self?.show(s) } }
        station.onTitle = { [weak self] t in Task { @MainActor in self?.title = t } }
        news.onActive = { [weak self] on in
            self?.newsActive = on
            announce(on ? L.t(.newsOnAir) : L.f(.backTo, self?.current?.displayName ?? "Fona"))
        }
        news.onSkipped = { [weak self] on in self?.newsSkipped = on }
        news.log = { log.notice("\($0, privacy: .public)"); FileLog.shared.write($0) }
        FileLog.shared.write("start Fona \(version) (\(build))")
        if AppUpdater.translocated { notice = L.t(.moveToApplications) }
        updater.start()
        applyNewsSettings()
        news.setEnabled(settings.newsEnabled)
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyNewsSettings() }
        }
        player.volume = Float(settings.volume)
        settings.onVolume = { [weak self] v in self?.player.volume = Float(v) }
        if CommandLine.arguments.contains("--mute") { player.volume = 0; settings.onVolume = nil }
        // the last station is ready in the header after a restart – one click on Play (user request 2026-11-12)
        if let id = settings.lastStationID, let s = library.station(id) {
            if settings.resumeOnLaunch { play(s) } else { current = s }
        }
        // developer launch argument: --selftest (runs the self-test, sends the report, quits)
        if CommandLine.arguments.contains("--selftest") {
            selfTestQuits = true
            DispatchQueue.main.async { self.runSelfTest() }
        }
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
        FileLog.shared.write("play \(s.source == .custom ? "own link" : "directory station")")
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
        // the programme counts as on while it connects, buffers or reconnects: switching stations must not restart the
        // silent news chain (the log showed stop/start on every change)
        let on: Bool
        switch s { case .stopped, .failed: on = false; default: on = true }
        news.program(playing: on, url: current?.url)
        switch s {
        case .playing: player.setPlaying(true)
        case .reconnecting(let n) where n == 1: announce(L.f(.reconnecting, n, StationPlayer.defaultRetryDelays.count))
        case .failed(let r): player.setPlaying(false); log.error("stream failed: \(r.code, privacy: .public)")
            announce(Messages.text(r, L.language))
            FileLog.shared.write("stream failed: \(r.code)")
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
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; searchError = nil; searching = false; browseMore(); return }
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

    /// Next A–Z page of the directory; starts over when the countries changed. Called as the list scrolls to its end.
    func browseMore() {
        let keys = AlphaMerge(countries: settings.countries).keys
        if browse.keys != keys { browseTask?.cancel(); browseTask = nil; browse = AlphaMerge(countries: settings.countries); browseFailed = false }
        guard browseTask == nil, !browse.finished else { return }
        let want = browse.hungry.map { ($0, browse.offset[$0] ?? 0) }
        browseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pages = try await withThrowingTaskGroup(of: (String, [RadioBrowser.Result], Bool).self) { group in
                    for (k, off) in want { group.addTask { let p = try await self.directory.browse(country: k.isEmpty ? nil : k, offset: off); return (k, p.stations, p.more) } }
                    return try await group.reduce(into: []) { $0.append($1) }
                }
                guard !Task.isCancelled, self.browse.keys == keys else { return }
                let before = self.browse.shown.count
                for (k, st, more) in pages { self.browse.add(k, st, more: more) }
                self.browseFailed = false
                // the spinner row stays on screen (no new onAppear) when a page added little: fetch on by ourselves
                if self.browse.shown.count - before < 50 { self.browseTask = nil; self.browseMore(); return }
            } catch {
                guard !Task.isCancelled else { return }
                self.browseFailed = true
            }
            self.browseTask = nil
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

    @Published var selfTestRunning = false
    var selfTestQuits = false
    @Published var problemSheet = false

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// Self-test (PLAN §9): the check catalogue (no network) plus live checks of radio-browser and Deutschlandfunk
    /// (skipped when offline), then an anonymous report.
    func runSelfTest() {
        guard !selfTestRunning else { return }
        selfTestRunning = true
        showToast(L.t(.selfTestRunning))
        Task {
            let t0 = Date()
            let checks = await Task.detached { CheckCatalog.runAll() }.value
            var results = Report.results(from: checks, seconds: Date().timeIntervalSince(t0))
            results += await networkChecks()
            let failed = checks.filter { !$0.passed }.count + results.filter { $0.id.hasPrefix("live-") && $0.status == "fail" }.count
            for f in checks where !f.passed { FileLog.shared.write("self-test failed: \(f.id)") }
            FileLog.shared.write("self-test: \(failed) failed of \(checks.count + 2)")
            let report = Report(kind: "selftest", app: version, build: build, date: ISO8601DateFormatter().string(from: Date()),
                                system: Report.systemInfo(language: L.language.rawValue), results: results,
                                durationSeconds: (Date().timeIntervalSince(t0) * 10).rounded() / 10,
                                log: Report.anonymize(FileLog.shared.tail()), note: nil, contact: nil)
            let outcome = await Reporter.send(report)
            selfTestRunning = false
            let summary = failed == 0 ? L.f(.selfTestPassed, checks.count + 2) : L.f(.selfTestFailed, failed, checks.count + 2)
            showToast(summary + " " + outcomeText(outcome))
            log.notice("self-test done: \(summary, privacy: .public) \(String(describing: outcome), privacy: .public)")
            if selfTestQuits { NSApp.terminate(nil) }
        }
    }

    func networkChecks() async -> [Report.Result] {
        func result(_ id: String, _ t0: Date, _ status: String, _ detail: String) -> Report.Result {
            Report.Result(id: id, title: id, status: status, detail: detail, seconds: (Date().timeIntervalSince(t0) * 10).rounded() / 10)
        }
        var out: [Report.Result] = []
        var t0 = Date()
        do {
            let r = try await directory.search("radio", countries: ["DE"])
            out.append(result("live-directory", t0, r.isEmpty ? "fail" : "pass", "\(r.count) results"))
        } catch {
            out.append(result("live-directory", t0, "skip", "offline or directory unreachable: \((error as? Rejection)?.code ?? "network")"))
        }
        t0 = Date()
        do {
            var frames = 0, titles = 0
            for try await e in try await StreamSource.open(NewsWatcher.newsURL) {
                if case .frames = e { frames += 1 }
                if case .title = e { titles += 1 }
                if frames >= 20 || Date().timeIntervalSince(t0) > 10 { break }
            }
            out.append(result("live-news-station", t0, frames > 0 ? "pass" : "fail", "\(frames) frame blocks, titles \(titles > 0 ? "yes" : "no")"))
        } catch {
            out.append(result("live-news-station", t0, "skip", "unreachable: \((error as? Rejection)?.code ?? "network")"))
        }
        return out
    }

    func outcomeText(_ o: Reporter.Outcome) -> String {
        switch o { case .sent: return L.t(.reportSent); case .saved: return L.t(.reportSaved); case .failed: return L.t(.reportFailed) }
    }

    func sendProblem(text: String, contact: String, attach: Bool) {
        let report = Report(kind: "problem", app: version, build: build, date: ISO8601DateFormatter().string(from: Date()),
                            system: attach ? Report.systemInfo(language: L.language.rawValue) : [:], results: [], durationSeconds: 0,
                            log: attach ? Report.anonymize(FileLog.shared.tail()) : [], note: String(text.prefix(5000)),
                            contact: contact.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(contact.prefix(200)))
        Task {
            let o = await Reporter.send(report)
            if case .saved(let url) = o { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            showToast(outcomeText(o))
        }
    }

    func showToast(_ text: String) {
        toast = text
        announce(text)
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); if self.toast == text { self.toast = nil } }
    }

    // MARK: news

    func applyNewsSettings() {
        news.configure(halfHours: settings.newsSchedule == .hourlyAndHalf, maxMinutes: settings.newsMaxMinutes)
        news.setEnabled(settings.newsEnabled)
    }

    func backFromNews() { news.backNow() }
    func rejoinNews() { news.rejoin() }

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
