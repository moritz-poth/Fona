import Foundation

/// A station the user wants as a news station (P8): while it learns, Fona listens to it silently in the background;
/// afterwards it carries the learned profile. Kept in news/stations.json in the app container.
public struct LearnedStation: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case learning, ready, failed }
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Date; public var frames: Int
        public init(start: Date, frames: Int) { self.start = start; self.frames = frames }
    }

    public let id: UUID
    public var name: String
    public let url: String
    public var state: State = .learning
    public var segments: [Segment] = []
    public var profile: LearnedNews?

    public init(id: UUID = UUID(), name: String, url: String) { self.id = id; self.name = name; self.url = url }

    public var learnedSeconds: Double { Double(segments.reduce(0) { $0 + $1.frames }) / Fingerprinter.framesPerSecond }
    public var source: NewsSource? { profile.map { NewsSource(name: name, url: url, learned: $0) } }

    static let maxStations = 20, maxSegments = 2000

    /// A3: the file is checked like foreign data.
    func isValid() -> Bool {
        guard name.count <= 120, Sanitize.display(name) == name, url.utf8.count <= Limits.maxURLLength,
              case .success = URLPolicy.check(url, .stream), segments.count <= Self.maxSegments,
              segments.allSatisfy({ $0.frames >= 0 && $0.frames <= Int(NewsLearning.maxSeconds * Fingerprinter.framesPerSecond) }) else { return false }
        return profile.map { $0.checked() != nil } ?? true
    }

    public static func load(_ data: Data) -> [LearnedStation]? {
        guard data.count <= 4 * 1024 * 1024 else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([LearnedStation].self, from: data), list.count <= maxStations,
              list.allSatisfy({ $0.isValid() }), Set(list.map(\.id)).count == list.count else { return nil }
        return list
    }
}

/// Fingerprints the learning stream and appends them to <id>.fp; starts a new segment after gaps.
final class LearnSink: PCMSink, @unchecked Sendable {
    let lock = NSLock()
    var fp = Fingerprinter()
    var pending: [UInt32] = []
    var segStart: Date?
    var segFrames = 0
    /// (segment start, new frames of that segment), every 30 s and before a new segment starts.
    var onFrames: (@Sendable (Date, [UInt32]) -> Void)?

    var bufferedSeconds: Double { 2 }  // StationPlayer only waits for this before it reports "playing"

    func reset() {
        lock.lock(); fp = Fingerprinter(); segStart = nil; segFrames = 0; pending.removeAll(); lock.unlock()
    }

    func write(_ pcm: [Float]) async throws {
        lock.lock()
        let now = Date()
        let new = fp.feed(pcm)
        var emit: [(Date, [UInt32])] = []
        // a reconnect or a stall leaves a hole: the clock ran on, the audio did not → new segment
        if let s = segStart, now.timeIntervalSince(s) - Double(segFrames) / Fingerprinter.framesPerSecond > 10 {
            if !pending.isEmpty { emit.append((s, pending)); pending.removeAll() }
            segStart = nil
        }
        if segStart == nil { segStart = now.addingTimeInterval(-Double(new.count) / Fingerprinter.framesPerSecond); segFrames = 0 }
        segFrames += new.count
        pending += new
        if pending.count >= Int(30 * Fingerprinter.framesPerSecond) { emit.append((segStart!, pending)); pending.removeAll() }
        lock.unlock()
        for (start, frames) in emit { onFrames?(start, frames) }
    }
}

/// Learns news stations in the background (P8). One station at a time; all calls on the main thread.
@MainActor
public final class NewsLearning {
    /// 8 h of audio give ≥ 8 :00 and 8 :30 slots (research: 6–12 h). Without a result Fona goes on up to 16 h.
    nonisolated public static let targetSeconds = 8 * 3600.0, maxSeconds = 16 * 3600.0
    static let maxTitleBytes = 2 * 1024 * 1024

    let dir: URL
    let sink = LearnSink()
    let player: StationPlayer
    public private(set) var stations: [LearnedStation] = []
    public var onChange: (() -> Void)?
    public var log: ((String) -> Void)?
    var running: UUID?
    var retry: Timer?
    var computing = false

    public init(directory: URL, makeDecoder: @escaping @Sendable () -> FrameDecoder) {
        dir = directory.appendingPathComponent("news")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        player = StationPlayer(sink: sink, makeDecoder: makeDecoder)
        if let d = FileManager.default.contents(atPath: file.path) {
            if let list = LearnedStation.load(d) { stations = list } else {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("stations.broken.json"))
                try? FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("stations.broken.json"))
            }
        }
        sink.onFrames = { [weak self] start, fp in Task { @MainActor in self?.got(start, fp) } }
        player.onTitle = { [weak self] t in Task { @MainActor in self?.title(t) } }
        player.onState = { [weak self] s in
            // the learning chain never gives up: a minute later it tries again (it runs for hours)
            if case .failed = s { Task { @MainActor in self?.scheduleRetry() } }
        }
        update()
    }

    var file: URL { dir.appendingPathComponent("stations.json") }
    func fpFile(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).fp") }
    func titleFile(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).titles") }

    /// Starts learning a station (again, if it is already in the list).
    public func learn(name: String, url: String) {
        guard case .success = URLPolicy.check(url, .stream) else { return }
        if let i = stations.firstIndex(where: { NewsWatcher.sameStream($0.url, url) }) { remove(stations[i].id) }
        guard stations.count < LearnedStation.maxStations else { return }
        let clean = String(Sanitize.display(name).prefix(120))
        stations.append(LearnedStation(name: clean.isEmpty ? "?" : clean, url: url))
        save(); update()
    }

    public func remove(_ id: UUID) {
        if running == id { stopChain() }
        stations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fpFile(id))
        try? FileManager.default.removeItem(at: titleFile(id))
        save(); update()
    }

    /// Plays the first station that still learns (silently), or nothing.
    func update() {
        let next = computing ? nil : stations.first { $0.state == .learning }?.id
        guard next != running else { return }
        stopChain()
        guard let id = next, let s = stations.first(where: { $0.id == id }) else { onChange?(); return }
        running = id
        log?("news learning: start")
        player.play(s.url)
        onChange?()
    }

    func stopChain() {
        retry?.invalidate(); retry = nil
        player.stop()
        running = nil
    }

    func scheduleRetry() {
        guard let id = running else { return }
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running == id, let s = self.stations.first(where: { $0.id == id }) else { return }
                self.player.play(s.url)
            }
        }
    }

    func append(_ data: Data, to url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? h.close() }
        do { _ = try h.seekToEnd(); try h.write(contentsOf: data); return true } catch { return false }
    }

    /// learned seconds at the last computation (in memory: after a restart Fona computes at the next chunk)
    var computedAt: [UUID: Double] = [:]

    func got(_ start: Date, _ fp: [UInt32]) {
        guard let id = running, let i = stations.firstIndex(where: { $0.id == id }),
              stations[i].segments.count < LearnedStation.maxSegments,
              append(fp.withUnsafeBufferPointer { Data(buffer: $0) }, to: fpFile(id)) else { return }
        if let last = stations[i].segments.last, last.start == start {
            stations[i].segments[stations[i].segments.count - 1].frames += fp.count
        } else {
            stations[i].segments.append(.init(start: start, frames: fp.count))
        }
        save()
        onChange?()
        let secs = stations[i].learnedSeconds
        // at 8 h, then every further hour until 16 h
        if secs >= Self.targetSeconds, secs - (computedAt[id] ?? -.infinity) >= 3600 || secs >= Self.maxSeconds {
            computedAt[id] = secs
            compute(id)
        }
    }

    func title(_ t: String) {
        guard let id = running else { return }
        let line = "\(Int(Date().timeIntervalSince1970))\t\(t.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " "))\n"
        let url = titleFile(id)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size < Self.maxTitleBytes else { return }
        _ = append(Data(line.utf8), to: url)
    }

    /// Reads the raw data back and learns off the main thread; ready when something usable came out.
    func compute(_ id: UUID) {
        guard !computing, let s = stations.first(where: { $0.id == id }) else { return }
        computing = true
        update()  // the chain pauses while the computer works
        let fpURL = fpFile(id), tURL = titleFile(id), segInfo = s.segments, final = s.learnedSeconds >= Self.maxSeconds
        log?("news learning: compute after \(Int(s.learnedSeconds / 60)) min")
        Task.detached(priority: .utility) {
            let raw = FileManager.default.contents(atPath: fpURL.path) ?? Data()
            let all: [UInt32] = raw.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            var segs: [NewsLearner.Segment] = [], at = 0
            for g in segInfo where at + g.frames <= all.count {
                segs.append(.init(start: g.start, frames: Array(all[at..<at + g.frames]))); at += g.frames
            }
            let titles: [(Date, String)] = String(decoding: FileManager.default.contents(atPath: tURL.path) ?? Data(), as: UTF8.self).split(separator: "\n").compactMap { l in
                let p = l.split(separator: "\t", maxSplits: 1)
                guard p.count == 2, let t = Double(p[0]) else { return nil }
                return (Date(timeIntervalSince1970: t), Sanitize.display(String(p[1])))
            }
            let profile = NewsLearner.learn(segments: segs, titles: titles).checked()
            await MainActor.run { self.finish(id, profile, final: final) }
        }
    }

    func finish(_ id: UUID, _ profile: LearnedNews?, final: Bool) {
        computing = false
        if let i = stations.firstIndex(where: { $0.id == id }) {
            if let p = profile, p.usable {
                stations[i].profile = p; stations[i].state = .ready
                try? FileManager.default.removeItem(at: fpFile(id)); try? FileManager.default.removeItem(at: titleFile(id))
                log?("news learning: ready, \(p.markers.count) markers, \(p.newsTitles.count) titles, \(p.explained)/\(p.slots) slots")
            } else if final {
                stations[i].state = .failed
                try? FileManager.default.removeItem(at: fpFile(id)); try? FileManager.default.removeItem(at: titleFile(id))
                log?("news learning: nothing found")
            }
            save()
        }
        update()
        onChange?()
    }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(stations) else { return }
        try? d.write(to: file, options: .atomic)
    }
}
