import Foundation

/// What Fona learned about a news station (P8): start markers (fingerprints near :00/:30) and/or the titles the
/// station sends while the news is on. Stored as JSON in the app container and checked like foreign data on load.
public struct LearnedNews: Codable, Equatable, Sendable {
    public var markers: [NewsMarker] = []
    /// Normalised titles ("#" for digits) that mean "news is on" …
    public var newsTitles: [String] = []
    /// … and the station slogan that follows them while the news still runs (Bayern 3, hr-iNFO).
    public var fillerTitles: [String] = []
    /// Median bulletin length from the titles; nil = no titles to measure.
    public var typicalSeconds: Double?
    /// :00/:30 slots of the learning hours the markers explained, and all slots.
    public var explained = 0, slots = 0

    public init() {}
    public var usable: Bool { !markers.isEmpty || !newsTitles.isEmpty }

    static let maxMarkers = 6, maxTemplate = 200, maxTitles = 8, maxTitleLength = 300

    /// A3: limits and sane numbers, or nil.
    public func checked() -> LearnedNews? {
        guard markers.count <= Self.maxMarkers, newsTitles.count <= Self.maxTitles, fillerTitles.count <= Self.maxTitles,
              markers.allSatisfy({ !$0.template.isEmpty && $0.template.count <= Self.maxTemplate && $0.offset.isFinite
                  && abs($0.offset) <= 120 && $0.threshold.isFinite && (0...0.5).contains($0.threshold) }),
              (newsTitles + fillerTitles).allSatisfy({ !$0.isEmpty && $0.count <= Self.maxTitleLength && Sanitize.display($0) == $0 }),
              typicalSeconds.map({ $0.isFinite && (30...1200).contains($0) }) ?? true,
              (0...10_000).contains(explained), (0...10_000).contains(slots) else { return nil }
        return self
    }

    /// Digits → "#", runs of spaces → one (same as spikes/newslearn/titles.py).
    public static func normalize(_ t: String) -> String {
        var out = "", lastSpace = false, lastHash = false
        for ch in t.trimmingCharacters(in: .whitespaces) {
            if ch.isNumber && ch.isASCII { if !lastHash { out.append("#") }; lastHash = true; lastSpace = false; continue }
            lastHash = false
            if ch == " " || ch == "\t" { if !lastSpace { out.append(" ") }; lastSpace = true; continue }
            lastSpace = false
            out.append(ch)
        }
        return out
    }
}

/// Learns a station from hours of silent listening (P8, ported from spikes/newslearn: learn.py learn_starts,
/// titles.py learn). Pure computation, no I/O; slow (seconds to a minute) – run it off the main thread.
public enum NewsLearner {
    static let fps = Fingerprinter.framesPerSecond
    public static let pre = 120.0, post = 150.0, window = 90.0

    /// Fingerprints of one stretch of listening; `start` = wall-clock time of frame 0.
    public struct Segment: Sendable {
        public var start: Date
        public var frames: [UInt32]
        public init(start: Date, frames: [UInt32]) { self.start = start; self.frames = frames }
    }

    public static func learn(segments: [Segment], titles: [(Date, String)], calendar: Calendar = .current) -> LearnedNews {
        var r = LearnedNews()
        let (markers, explained, slots) = learnStarts(segments: segments, calendar: calendar)
        r.markers = markers; r.explained = explained; r.slots = slots
        let t = learnTitles(titles)
        r.newsTitles = t.news; r.fillerTitles = t.filler; r.typicalSeconds = t.typical
        return r
    }

    // MARK: start markers

    /// :00 and :30 positions (frame index into the joined fingerprint) of every segment.
    static func marks(_ segs: [Segment], _ cal: Calendar) -> (fp: [UInt32], marks: [Int]) {
        var fp: [UInt32] = [], marks: [Int] = []
        for s in segs {
            let base = fp.count
            fp += s.frames
            let end = s.start.addingTimeInterval(Double(s.frames.count) / fps)
            var c = cal.dateComponents([.year, .month, .day, .hour], from: s.start)
            var t = cal.date(from: c) ?? s.start
            while t < end {
                for half in [0.0, 1800] {
                    let m = t.addingTimeInterval(half)
                    let i = base + Int(m.timeIntervalSince(s.start) * fps)
                    if i >= base && i < base + s.frames.count { marks.append(i) }
                }
                c.hour = (c.hour ?? 0) + 1
                t = cal.date(from: c) ?? end
            }
        }
        return (fp, marks)
    }

    public static func learnStarts(segments: [Segment], calendar: Calendar = .current, maxMarkers: Int = 6)
        -> (markers: [NewsMarker], explained: Int, slots: Int) {
        let (fp, all) = marks(segments, calendar)
        let preF = Int(pre * fps), postF = Int(post * fps), winF = Int(window * fps)
        let tops = all.filter { $0 - preF >= 0 && $0 + postF < fp.count }
        guard tops.count >= 3 else { return ([], 0, tops.count) }
        let W = tops.map { Array(fp[($0 - preF)..<($0 + postF)]) }
        let cov = coverage(W, maxLag: Int(90 * fps))
        var excl = [Bool](repeating: false, count: fp.count)
        for p in all { for i in max(0, p - winF)..<min(fp.count, p + winF) { excl[i] = true } }

        struct Cand { var marker: NewsMarker; var neg: Double; var hits: Set<Int> }
        var tasks: [(w: Int, s: Int, len: Int)] = []
        var seen = Set<[UInt32]>()
        for (wi, c) in cov.enumerated() {
            for (a, b) in regions(c.map { $0 >= 1 }, minLength: Int(2 * fps)) {
                for len in [Int(2 * fps), Int(4 * fps)] {
                    var s = a
                    while s + len <= b {
                        let key = [UInt32(len), UInt32(truncatingIfNeeded: (s - preF) / Int(fps))] + W[wi][s..<s + 4]
                        if seen.insert(key).inserted { tasks.append((wi, s, len)) }
                        s += Int(fps)
                    }
                }
            }
        }
        var results = [Cand?](repeating: nil, count: tasks.count)
        fp.withUnsafeBufferPointer { stream in
            excl.withUnsafeBufferPointer { ex in
                results.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: tasks.count) { k in
                        let t = tasks[k]
                        let tpl = Array(W[t.w][t.s..<t.s + t.len])
                        let sc = tpl.withUnsafeBufferPointer { scan(stream, $0) }
                        var neg = 1.0
                        for i in 0..<sc.count where !ex[i] && sc[i] < neg { neg = sc[i] }
                        let thr = min(0.40, neg - 0.25)  // a clear gap to everything outside the :00/:30 windows
                        guard thr >= 0.15 else { return }
                        var hits = Set<Int>()
                        for (mi, m) in tops.enumerated() {
                            let lo = max(0, m - winF), hi = min(sc.count, m + winF)
                            if lo < hi, sc[lo..<hi].min()! < thr { hits.insert(mi) }
                        }
                        guard hits.count >= 2 else { return }
                        out[k] = Cand(marker: NewsMarker(template: tpl, offset: Double(t.s - preF) / fps, threshold: thr), neg: neg, hits: hits)
                    }
                }
            }
        }
        // greedy set cover: several markers per station (day/night, weekday/weekend openers)
        let cands = results.compactMap { $0 }
        var chosen: [NewsMarker] = [], covered = Set<Int>()
        while chosen.count < maxMarkers,
              let best = cands.max(by: { ($0.hits.subtracting(covered).count, $0.neg) < ($1.hits.subtracting(covered).count, $1.neg) }),
              best.hits.subtracting(covered).count >= 2 {
            chosen.append(best.marker); covered.formUnion(best.hits)
        }
        return (chosen, covered.count, tops.count)
    }

    /// Share of non-matching frames of `tpl` at every position of `stream`.
    static func scan(_ stream: UnsafeBufferPointer<UInt32>, _ tpl: UnsafeBufferPointer<UInt32>) -> [Double] {
        let n = stream.count - tpl.count + 1
        guard n > 0 else { return [] }
        var out = [Double](repeating: 1, count: n)
        for i in 0..<n { out[i] = NewsMarker.score(stream, i, tpl) }
        return out
    }

    static func regions(_ mask: [Bool], minLength: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = [], start: Int?
        for (i, m) in (mask + [false]).enumerated() {
            if m, start == nil { start = i }
            if !m, let s = start { if i - s >= minLength { out.append((s, i)) }; start = nil }
        }
        return out
    }

    /// Per window and frame: in how many other windows the same sound occurs (lag up to maxLag), lags proposed by
    /// exact and 1-bit-flip fingerprint hits (learn.py coverage_fast / candidate_lags).
    static func coverage(_ W: [[UInt32]], maxLag: Int, thr: Double = 0.30) -> [[Int]] {
        let L = W[0].count, sm = Int(fps)
        var cov = [[Int]](repeating: [Int](repeating: 0, count: L), count: W.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: W.count) { i in
            var mine = [Int](repeating: 0, count: L)
            for j in W.indices where j != i {
                var best = [Bool](repeating: false, count: L)
                for lag in candidateLags(W[i], W[j], maxLag: maxLag) {
                    let lo = max(0, -lag), hi = min(L, L - lag)
                    guard hi - lo >= sm else { continue }
                    // moving average of the bit error rate over 1 s, normalised at the edges
                    var ber = [Double](repeating: 0, count: hi - lo)
                    for k in lo..<hi { ber[k - lo] = Double((W[i][k] ^ W[j][k + lag]).nonzeroBitCount) / 32 }
                    var prefix = [Double](repeating: 0, count: ber.count + 1)
                    for k in ber.indices { prefix[k + 1] = prefix[k] + ber[k] }
                    for k in ber.indices {
                        let a = max(0, k - sm / 2), b = min(ber.count, k - sm / 2 + sm)
                        if (prefix[b] - prefix[a]) / Double(b - a) < thr { best[k + lo] = true }
                    }
                }
                for k in 0..<L where best[k] { mine[k] += 1 }
            }
            lock.lock(); cov[i] = mine; lock.unlock()
        }
        return cov
    }

    static func candidateLags(_ a: [UInt32], _ b: [UInt32], maxLag: Int, minVotes: Int = 3) -> [Int] {
        var counts: [UInt32: Int] = [:]
        for v in a { counts[v, default: 0] += 1 }
        for v in b { counts[v, default: 0] += 1 }
        let limit = max(40, (a.count + b.count) / 200)
        let common: (UInt32) -> Bool = { v in v == 0 || v == .max || (counts[v] ?? 0) > limit }
        var idx: [UInt32: [Int]] = [:]
        for (j, v) in b.enumerated() where !common(v) { idx[v, default: []].append(j) }
        var votes: [Int: Int] = [:]
        for (i, v) in a.enumerated() where !common(v) {
            for f in [UInt32(0)] + (0..<32).map({ UInt32(1) << UInt32($0) }) {
                for j in idx[v ^ f] ?? [] where abs(j - i) <= maxLag {
                    votes[Int((Double(j - i) / 4).rounded(.down)), default: 0] += 1  // bins of 4 frames
                }
            }
        }
        var lags = Set<Int>()
        for (k, n) in votes where n >= minVotes { lags.formUnion((4 * k - 2)..<(4 * k + 6)) }
        return lags.sorted()
    }

    // MARK: titles

    static func isNewsWord(_ t: String) -> Bool {
        // whole word: not "Nachrichtenradio", "…-Nachrichtenredaktion"
        t.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == "nachrichten" || $0 == "news" }
    }

    static func clusters(_ times: [Date], gap: Double = 180) -> [(Date, Date)] {
        var out: [(Date, Date)] = []
        for t in times {
            if let last = out.last, t.timeIntervalSince(last.1) <= gap { out[out.count - 1].1 = t } else { out.append((t, t)) }
        }
        return out
    }

    /// News title = news word + comes in short clusters (≤ 12 min, ≤ 2.5 per hour) in ≥ 25 % of the hours.
    /// Filler = the title that follows within 90 s in ≥ 30 % of the bulletins. Typical = median bulletin length.
    public static func learnTitles(_ raw: [(Date, String)]) -> (news: [String], filler: [String], typical: Double?) {
        let log = raw.map { ($0.0, LearnedNews.normalize($0.1)) }.filter { !$0.1.isEmpty && $0.1.count <= LearnedNews.maxTitleLength }
        guard let first = log.first?.0, let last = log.last?.0 else { return ([], [], nil) }
        let hours = max(1, last.timeIntervalSince(first) / 3600)
        var news = Set<String>()
        for t in Set(log.map(\.1)) where isNewsWord(t) {
            let cl = clusters(log.filter { $0.1 == t }.map(\.0))
            let spans = cl.map { $0.1.timeIntervalSince($0.0) / 60 }.sorted()
            let hrs = Set(cl.map { Int($0.0.timeIntervalSince1970 / 3600) })
            if Double(hrs.count) >= 0.25 * hours, Double(cl.count) <= 2.5 * hours, spans[spans.count / 2] <= 12 { news.insert(t) }
        }
        guard !news.isEmpty else { return ([], [], nil) }
        let onsets = clusters(log.filter { news.contains($0.1) }.map(\.0)).map(\.0)
        var follow: [String: Int] = [:]
        for o in onsets {
            if let n = log.first(where: { $0.0 > o && !news.contains($0.1) }), n.0.timeIntervalSince(o) <= 90 { follow[n.1, default: 0] += 1 }
        }
        let filler = Set(follow.filter { Double($0.value) >= 0.3 * Double(onsets.count) }.keys)
        var lens: [Double] = []
        for o in onsets {
            if let e = log.first(where: { $0.0 > o && !news.contains($0.1) && !filler.contains($0.1) }) {
                lens.append(min(e.0.timeIntervalSince(o), 720))
            }
        }
        lens.sort()
        let typical = lens.isEmpty ? nil : max(30, lens[lens.count / 2])
        return (Array(news.sorted().prefix(LearnedNews.maxTitles)), Array(filler.sorted().prefix(LearnedNews.maxTitles)), typical)
    }
}
