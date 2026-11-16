import Foundation
import Accelerate

/// 32-bit audio fingerprint per 32 ms (P8, same scheme as spikes/newslearn/fp.py, Haitsma–Kalker style):
/// 48 kHz stereo → 8 kHz mono, 64 ms Hann window, 32 ms hop (31.25 frames/s), 33 log bands 300–3000 Hz,
/// bit = sign of the change over time of the energy difference of neighbouring bands. The same sound through two
/// encodes differs in ≈ 10–20 % of the bits, unrelated sound in ≈ 50 %. Learning and detection both run through this
/// type, so the cheap 6:1 decimation (box filter) is the same on both sides.
public final class Fingerprinter: @unchecked Sendable {
    public static let framesPerSecond = 8000.0 / 256
    static let window = 512, hop = 256, decimate = 6
    static let edges: [Double] = (0...33).map { 300 * pow(10, log10(3000.0 / 300) * Double($0) / 33) }
    /// FFT bin range per band (bin width 15.625 Hz)
    static let bands: [Range<Int>] = (0..<33).map { i in
        let lo = Int((edges[i] / 15.625).rounded(.up)), hi = Int((edges[i + 1] / 15.625).rounded(.up))
        return lo..<max(lo + 1, hi)
    }

    let setup: vDSP_DFT_Setup
    let hann: [Float]
    var mono: [Float] = []
    var acc: Float = 0, accN = 0
    var prevDiff: [Float]?

    public init() {
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.window), .FORWARD)!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.window, isHalfWindow: false)
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    /// Feeds interleaved 48 kHz stereo PCM; returns the fingerprints of all frames completed by this call.
    public func feed(_ pcm: [Float]) -> [UInt32] {
        var i = 0
        while i + 1 < pcm.count {
            acc += pcm[i] + pcm[i + 1]; accN += 1; i += 2
            if accN == Self.decimate { mono.append(acc / Float(2 * Self.decimate)); acc = 0; accN = 0 }
        }
        var out: [UInt32] = []
        var at = 0
        while mono.count - at >= Self.window {
            out.append(frame(at))
            at += Self.hop
        }
        if at > 0 { mono.removeFirst(at) }
        return out
    }

    func frame(_ at: Int) -> UInt32 {
        let n = Self.window
        var x = [Float](repeating: 0, count: n)
        mono.withUnsafeBufferPointer { m in vDSP_vmul(m.baseAddress! + at, 1, hann, 1, &x, 1, vDSP_Length(n)) }
        var inR = [Float](repeating: 0, count: n / 2), inI = inR, outR = inR, outI = inR
        for k in 0..<n / 2 { inR[k] = x[2 * k]; inI[k] = x[2 * k + 1] }
        vDSP_DFT_Execute(setup, inR, inI, &outR, &outI)
        var energy = [Float](repeating: 0, count: 33)
        for (b, r) in Self.bands.enumerated() {
            var e: Float = 0
            for k in r where k < n / 2 { e += outR[k] * outR[k] + outI[k] * outI[k] }
            energy[b] = e
        }
        let diff = (0..<32).map { energy[$0] - energy[$0 + 1] }
        defer { prevDiff = diff }
        guard let p = prevDiff else { return 0 }
        var v: UInt32 = 0
        for b in 0..<32 where diff[b] - p[b] > 0 { v |= 1 << UInt32(b) }
        return v
    }
}

/// A learned start marker: a few seconds of fingerprint that open the news, `offset` seconds after the news start
/// (negative = before :00, e.g. a jingle ahead of the hour).
public struct NewsMarker: Codable, Equatable, Sendable {
    public var template: [UInt32]
    public var offset: Double
    /// Share of template frames that may differ (more than 11 of 32 bits) for a match, 0…1.
    public var threshold: Double

    public init(template: [UInt32], offset: Double, threshold: Double) {
        self.template = template; self.offset = offset; self.threshold = threshold
    }

    /// Share of frames of `template` that do not match `stream` at position `at` (0 = perfect, ~1 = unrelated).
    static func score(_ stream: UnsafeBufferPointer<UInt32>, _ at: Int, _ template: UnsafeBufferPointer<UInt32>) -> Double {
        var bad = 0
        for k in 0..<template.count where (stream[at + k] ^ template[k]).nonzeroBitCount > 11 { bad += 1 }
        return Double(bad) / Double(template.count)
    }
}

/// Watches the fingerprint stream for learned markers; reports how long ago the news started.
public final class MarkerDetector: @unchecked Sendable {
    let markers: [NewsMarker]
    let fp = Fingerprinter()
    var recent: [UInt32] = []
    var framesSeen = 0
    var quietUntil = 0  // one report per bulletin (30 s)

    public init(markers: [NewsMarker]) { self.markers = markers.filter { !$0.template.isEmpty } }

    /// Feeds 48 kHz stereo PCM; returns "news started this many seconds ago" for every match completed by this call.
    public func feed(_ pcm: [Float]) -> [Double] {
        let maxLen = markers.map(\.template.count).max() ?? 0
        guard maxLen > 0 else { return [] }
        var found: [Double] = []
        for v in fp.feed(pcm) {
            recent.append(v); framesSeen += 1
            if recent.count > maxLen * 2 { recent.removeFirst(recent.count - maxLen) }
            guard framesSeen >= quietUntil else { continue }
            for m in markers where recent.count >= m.template.count {
                let s = recent.withUnsafeBufferPointer { r in m.template.withUnsafeBufferPointer { t in
                    NewsMarker.score(r, r.count - t.count, t) } }
                if s < m.threshold {
                    // the marker just ended: it started template.count frames ago, the news `offset` s before that
                    found.append(Double(m.template.count) / Fingerprinter.framesPerSecond + m.offset)
                    quietUntil = framesSeen + Int(30 * Fingerprinter.framesPerSecond)
                    break
                }
            }
        }
        return found
    }
}
