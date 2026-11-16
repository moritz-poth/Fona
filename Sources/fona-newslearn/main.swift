// Developer tool: fona-newslearn <recording dir> even|odd – the Swift port of spikes/newslearn on real recordings:
// fingerprints every hourly MP3 (cached as .fpw next to it), learns on even or odd hours and checks the markers on
// the other hours (like eval.py). Also prints the learned title rule from titles.log.
import Foundation
import FonaCore

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: fona-newslearn <dir> even|odd"); exit(1) }
let dir = URL(fileURLWithPath: args[1]), split = args[2]
let fm = FileManager.default
let files = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.range(of: #"^\d{8}-\d\d\.mp3$"#, options: .regularExpression) != nil }.sorted() ?? []
let hourFmt = DateFormatter(); hourFmt.dateFormat = "yyyyMMdd-HH"; hourFmt.timeZone = .current

func fingerprint(_ name: String) -> [UInt32] {
    let cache = dir.appendingPathComponent("fp").appendingPathComponent(name + ".fpw")
    if let d = fm.contents(atPath: cache.path) { return d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) } }
    guard let data = fm.contents(atPath: dir.appendingPathComponent(name).path) else { return [] }
    var g = FrameGuard(format: .mp3); let dec = DecoderCore(format: .mp3); let f = Fingerprinter()
    var out: [UInt32] = [], i = 0
    while i < data.count {
        let n = min(65_536, data.count - i)
        // AVAudioConverter autoreleases its buffers: without a pool a CLI grew to 22 GB (2026-11-16 crash)
        autoreleasepool { out += f.feed(dec.decode((try? g.feed(data.subdata(in: i..<i + n))) ?? Data())) }
        i += n
    }
    try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? out.withUnsafeBytes { Data($0) }.write(to: cache)
    return out
}

var segs: [(hour: Int, seg: NewsLearner.Segment)] = []
let fpsAll = files.map { f -> [UInt32] in fingerprint(f) }
for (k, f) in files.enumerated() {
    let h = hourFmt.date(from: String(f.prefix(11)))!
    let frames = fpsAll[k]
    // the first file starts when the recording started: it ends at the next full hour
    let start = k == 0 ? h.addingTimeInterval(3600 - Double(frames.count) / Fingerprinter.framesPerSecond) : h
    segs.append((Calendar.current.component(.hour, from: h), NewsLearner.Segment(start: start, frames: frames)))
}
let isTrain: (Int) -> Bool = { $0 % 2 == (split == "even" ? 0 : 1) }
// training = consecutive runs of train hours (each hour its own segment: the gaps are the test hours)
let train = segs.dropFirst().filter { isTrain($0.hour) }.map(\.seg)
let t0 = Date()
let (markers, explained, slots) = NewsLearner.learnStarts(segments: train)
print("== \(dir.lastPathComponent) \(split): \(train.count) train hours → \(markers.count) markers, explain \(explained)/\(slots) slots, \(Int(Date().timeIntervalSince(t0))) s")
for m in markers { print(String(format: "   %.1f s at %+.0f s, thr %.2f", Double(m.template.count) / Fingerprinter.framesPerSecond, m.offset, m.threshold)) }

// test: every detection in the test hours (and in the last minutes before them: :59 marks belong to the next hour)
var inWin = 0, outWin = 0, testSlots = 0
for (k, s) in segs.enumerated() where k > 0 && !isTrain(s.hour) {
    let joined = (k > 0 ? Array(segs[k - 1].seg.frames.suffix(Int(150 * Fingerprinter.framesPerSecond))) : []) + s.seg.frames
    let base = -Double(joined.count - s.seg.frames.count) / Fingerprinter.framesPerSecond
    var found = Set<Int>()
    for m in markers {
        joined.withUnsafeBufferPointer { st in m.template.withUnsafeBufferPointer { tp in
            var i = 0
            while i + tp.count <= st.count {
                var bad = 0
                for j in 0..<tp.count where (st[i + j] ^ tp[j]).nonzeroBitCount > 11 { bad += 1 }
                if Double(bad) / Double(tp.count) < m.threshold {
                    let newsAt = base + Double(i) / Fingerprinter.framesPerSecond - m.offset
                    let slot = Int((newsAt / 1800).rounded())
                    if abs(newsAt - Double(slot) * 1800) <= 90 { found.insert(slot) } else { outWin += 1 }
                    i += Int(30 * Fingerprinter.framesPerSecond)
                } else { i += 1 }
            }
        } }
    }
    inWin += found.filter { $0 == 0 || $0 == 1 }.count
    testSlots += 2
}
print("test: slots with detection \(inWin) of \(testSlots); outside windows \(outWin)")

// titles (wall clock)
if let text = try? String(contentsOf: dir.appendingPathComponent("titles.log"), encoding: .utf8) {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
    iso.timeZone = .current
    var log: [(Date, String)] = []
    for line in text.split(separator: "\n") {
        guard let r = line.range(of: "StreamTitle='"), let e = line.range(of: "';", range: r.upperBound..<line.endIndex),
              let d = iso.date(from: String(line.prefix(19))) else { continue }
        log.append((d, String(line[r.upperBound..<e.lowerBound])))
    }
    let t = NewsLearner.learnTitles(log)
    print("titles: news \(t.news.map { String($0.prefix(40)) }) filler \(t.filler.map { String($0.prefix(30)) }) typical \(t.typical.map { String(format: "%.0f s", $0) } ?? "–")")
}
