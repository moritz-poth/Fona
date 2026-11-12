import Foundation

/// Deutschlandfunk's news signal (PLAN §6.2, calibrated on 10 h of recordings 2026-11-12): the time signal before
/// the news – short pips at one-second spacing (≈ 0.1–0.2 s) and a long pip (≈ 0.75–0.8 s), all ≈ 780 Hz.
/// The silence after it varies (0.55–2.4 s), so it is not required. Streaming detector on 48 kHz interleaved stereo
/// PCM: 100 ms windows with 50 % overlap, Goertzel on 760–800 Hz, "tone ratio" = amplitude of the strongest bin /
/// RMS of the window (pure sine ≈ 0.707, speech/music far lower).
public struct NewsProfile: Sendable {
    public var frequencies: [Double] = [760, 770, 780, 790, 800]
    public var windowSeconds = 0.1
    public var toneRatio = 0.5
    public var shortPip: ClosedRange<Double> = 0.08...0.35
    public var longPip: ClosedRange<Double> = 0.55...1.2
    /// A short pip must start this long before the long pip (one or two seconds earlier).
    public var pipLead: [ClosedRange<Double>] = [0.8...1.2, 1.8...2.2]
    public var minLevelDBFS = -40.0          // the pips are loud (≈ −12 dBFS)
    public init() {}
    public static let deutschlandfunk = NewsProfile()
}

public final class ToneDetector: @unchecked Sendable {
    public struct Detection: Equatable, Sendable {
        /// Sample frame (48 kHz, counted since the detector started) of the first pip of the time signal.
        public let toneStartFrame: Int
        public let toneSeconds: Double
    }

    let profile: NewsProfile
    let sampleRate: Double
    let window: Int, hop: Int
    let coeffs: [Double]
    var mono: [Double] = []
    var framesSeen = 0         // frames consumed into `mono` so far
    var toneRun = 0            // consecutive tone hops
    var toneStart = 0
    var pips: [(start: Int, seconds: Double)] = []  // recent short pips
    public private(set) var lastRatio = 0.0

    public init(profile: NewsProfile = .deutschlandfunk, sampleRate: Double = DecoderCore.sampleRate) {
        self.profile = profile
        self.sampleRate = sampleRate
        window = Int(profile.windowSeconds * sampleRate)
        hop = window / 2
        coeffs = profile.frequencies.map { 2 * cos(2 * .pi * $0 / sampleRate) }
    }

    var hopSeconds: Double { Double(hop) / sampleRate }

    /// Feeds interleaved stereo PCM; returns detections completed by this call.
    public func feed(_ pcm: [Float]) -> [Detection] {
        var found: [Detection] = []
        mono.reserveCapacity(mono.count + pcm.count / 2)
        var i = 0
        while i + 1 < pcm.count { mono.append(Double(pcm[i] + pcm[i + 1]) * 0.5); i += 2 }
        framesSeen += pcm.count / 2
        var consumed = 0
        while mono.count - consumed >= window {
            let startFrame = framesSeen - (mono.count - consumed)
            if let d = analyse(consumed, startFrame) { found.append(d) }
            consumed += hop
        }
        if consumed > 0 { mono.removeFirst(consumed) }
        return found
    }

    func analyse(_ at: Int, _ startFrame: Int) -> Detection? {
        var energy = 0.0
        for k in at..<at + window { energy += mono[k] * mono[k] }
        let rms = (energy / Double(window)).squareRoot()
        var best = 0.0
        for c in coeffs {
            var s1 = 0.0, s2 = 0.0
            for k in at..<at + window { let s = mono[k] + c * s1 - s2; s2 = s1; s1 = s }
            best = max(best, (s1 * s1 + s2 * s2 - c * s1 * s2).squareRoot() / Double(window))
        }
        let level = 20 * log10(max(rms, 1e-9))
        let ratio = rms > 0 ? best / rms : 0
        lastRatio = ratio
        if ratio >= profile.toneRatio && level >= profile.minLevelDBFS {
            if toneRun == 0 { toneStart = startFrame }
            toneRun += 1
            return nil
        }
        guard toneRun > 0 else { return nil }
        let seconds = Double(toneRun + 1) * hopSeconds  // window overlap: n hops ≈ (n + 1) × hop of tone
        toneRun = 0
        // forget pips older than the longest lead
        let maxLead = profile.pipLead.map(\.upperBound).max() ?? 2.2
        pips.removeAll { Double(toneStart - $0.start) / sampleRate > maxLead + 0.5 }
        if profile.shortPip.contains(seconds) {
            pips.append((toneStart, seconds))
            return nil
        }
        guard profile.longPip.contains(seconds) else { return nil }
        let leading = pips.filter { p in
            let lead = Double(toneStart - p.start) / sampleRate
            return profile.pipLead.contains { $0.contains(lead) }
        }
        guard let first = leading.min(by: { $0.start < $1.start }) else { return nil }
        pips.removeAll()
        return Detection(toneStartFrame: first.start, toneSeconds: seconds)
    }
}
