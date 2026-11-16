import Foundation
import Testing
@testable import FonaCore

/// P8: fingerprint, marker detection, learning of start markers and news titles.
struct NewsLearnerTests {
    /// Deterministic noise, 48 kHz stereo.
    static func noise(_ seconds: Double, seed: UInt64) -> [Float] {
        var r = Rng(x: seed)
        return (0..<Int(seconds * 48_000)).flatMap { _ -> [Float] in
            let v = Float(Int(r.next() >> 40) - (1 << 23)) / Float(1 << 23) * 0.3
            return [v, v]
        }
    }

    /// A broadband "jingle": fixed noise with a rhythmic envelope (a pure tone fills one band only, the other bits
    /// would then follow the background noise – real jingles are broadband).
    static func jingle(_ seconds: Double) -> [Float] {
        let n = noise(seconds, seed: 42)
        return (0..<n.count).map { i -> Float in
            let t = Double(i / 2) / 48_000
            return n[i] * Float(0.9 + 0.6 * sin(2 * Double.pi * 3 * t))
        }
    }

    @Test func fingerprintFindsTheJingleAgainNotInNoise() {
        let tpl = Fingerprinter().feed(Self.noise(1, seed: 1) + Self.jingle(3))
        let marker = NewsMarker(template: Array(tpl[40..<100]), offset: 0, threshold: 0.4)
        // the same jingle with other noise around and a little noise over it
        var r = Rng(x: 9)
        let over = Self.jingle(3).map { $0 + Float(Int(r.next() >> 40) - (1 << 23)) / Float(1 << 23) * 0.02 }
        let hit = MarkerDetector(markers: [marker]).feed(Self.noise(2, seed: 2) + over + Self.noise(2, seed: 3))
        #expect(hit.count == 1)
        let miss = MarkerDetector(markers: [marker]).feed(Self.noise(8, seed: 4))
        #expect(miss.isEmpty)
    }

    @Test func learnsAMarkerAtTheHour() {
        // four hours of random fingerprints; the same 4 s "jingle" (with a few flipped bits) 5 s after every :00
        var r = Rng(x: 7)
        let fps = Fingerprinter.framesPerSecond
        let jingle = (0..<Int(4 * fps)).map { _ in UInt32(truncatingIfNeeded: r.next() >> 16) }
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(timeZone: .current, year: 2026, month: 11, day: 16, hour: 9, minute: 50))!
        var frames = (0..<Int(4 * 3600 * fps)).map { _ in UInt32(truncatingIfNeeded: r.next() >> 16) }
        for h in 0..<4 {
            let at = Int((600 + Double(h) * 3600 + 5) * fps)
            for k in jingle.indices { frames[at + k] = jingle[k] ^ (r.int(4) == 0 ? 1 << UInt32(r.int(32)) : 0) }
        }
        let (markers, explained, slots) = NewsLearner.learnStarts(segments: [.init(start: start, frames: frames)], calendar: cal)
        #expect(markers.count >= 1)
        #expect(explained >= 3)
        #expect(slots >= 6)
        if let m = markers.first { #expect(abs(m.offset - 5) <= 4) }
    }

    @Test func learnsNewsTitlesNotTheSlogan() {
        let t0 = Date(timeIntervalSince1970: 1_789_999_200)  // a full hour
        var log: [(Date, String)] = []
        for h in 0..<10 {
            let base = t0.addingTimeInterval(Double(h) * 3600)
            log.append((base.addingTimeInterval(-60), "Song \(h) - Artist"))
            log.append((base, "*** Nachrichten"))
            log.append((base.addingTimeInterval(9), "*** Station - die Nummer 1"))
            log.append((base.addingTimeInterval(220), "*** Wetter"))
            log.append((base.addingTimeInterval(300), "Das Nachrichtenradio"))  // a slogan that never goes away
            for m in stride(from: 600.0, to: 3500, by: 400) { log.append((base.addingTimeInterval(m), "Das Nachrichtenradio")) }
        }
        let t = NewsLearner.learnTitles(log)
        #expect(t.news == ["*** Nachrichten"])
        #expect(t.filler == ["*** Station - die Nummer #"])
        #expect(t.typical == 220)
    }

    @Test func checkedRefusesHostileProfiles() {
        var p = LearnedNews()
        p.markers = [NewsMarker(template: [1, 2, 3], offset: 4, threshold: 0.3)]
        #expect(p.checked() != nil)
        var bad = p; bad.markers[0].threshold = .nan; #expect(bad.checked() == nil)
        bad = p; bad.markers[0].offset = 1e9; #expect(bad.checked() == nil)
        bad = p; bad.markers = Array(repeating: p.markers[0], count: 7); #expect(bad.checked() == nil)
        bad = p; bad.newsTitles = [String(repeating: "x", count: 301)]; #expect(bad.checked() == nil)
        bad = p; bad.newsTitles = ["a\u{202E}b"]; #expect(bad.checked() == nil)
        bad = p; bad.typicalSeconds = -1; #expect(bad.checked() == nil)
    }
}
