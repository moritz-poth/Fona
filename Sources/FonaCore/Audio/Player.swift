import AVFoundation
import FonaAtomics

/// Lock-free single-producer/single-consumer ring for interleaved stereo PCM (decoder thread → render thread).
/// The render thread never waits and never takes a lock (a preempted writer holding a lock caused rare dropouts
/// in the soak test). Indices only grow; acquire/release ordering makes the copied samples visible before the index.
public final class PCMRing: @unchecked Sendable {
    let capacity: Int  // in samples (frames × 2)
    let data: UnsafeMutablePointer<Float>
    let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)   // producer-owned
    let consumed = UnsafeMutablePointer<Int>.allocate(capacity: 1)  // consumer-owned
    let clearRequest = UnsafeMutablePointer<Int>.allocate(capacity: 1)

    public init(seconds: Double) {
        capacity = Int(seconds * DecoderCore.sampleRate) * 2
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
        written.pointee = 0; consumed.pointee = 0; clearRequest.pointee = 0
    }
    deinit { data.deallocate(); written.deallocate(); consumed.deallocate(); clearRequest.deallocate() }

    var count: Int { fona_load_acquire(written) - fona_load_acquire(consumed) }
    public var fillSeconds: Double { Double(max(0, count) / 2) / DecoderCore.sampleRate }

    /// Producer: writes as much as fits; returns the number of samples written.
    @discardableResult
    public func write(_ s: [Float]) -> Int {
        let w = written.pointee
        let free = capacity - (w - fona_load_acquire(consumed))
        let n = min(s.count, free)
        guard n > 0 else { return 0 }
        let start = w % capacity
        let first = min(n, capacity - start)
        s.withUnsafeBufferPointer { src in
            (data + start).update(from: src.baseAddress!, count: first)
            if first < n { data.update(from: src.baseAddress! + first, count: n - first) }
        }
        fona_store_release(written, w + n)
        return n
    }

    /// Consumer (render thread): copies up to `n` samples, returns how many. Never blocks.
    func tryRead(_ out: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        serviceClear()
        let r = consumed.pointee
        let m = min(n, fona_load_acquire(written) - r)
        guard m > 0 else { return 0 }
        let start = r % capacity
        let first = min(m, capacity - start)
        out.update(from: data + start, count: first)
        if first < m { (out + first).update(from: data, count: m - first) }
        fona_store_release(consumed, r + m)
        return m
    }

    /// Any thread: asks the consumer to drop everything buffered (done on its next cycle).
    public func clear() { fona_store_release(clearRequest, 1) }

    /// Consumer side of `clear`: skip to the newest written sample.
    func serviceClear() {
        guard fona_load_acquire(clearRequest) != 0 else { return }
        fona_store_release(clearRequest, 0)
        fona_store_release(consumed, fona_load_acquire(written))
    }
}

/// One AVAudioSourceNode mixes two rings (programme, news) per sample with an 80 ms equal-power crossfade
/// (PLAN §3 Player, H7). Never touches the input node (no microphone prompt).
public final class Player: @unchecked Sendable {
    public static let crossfadeSeconds = 0.08

    public let program = PCMRing(seconds: 20)
    public let news = PCMRing(seconds: 20)
    let engine = AVAudioEngine()
    var node: AVAudioSourceNode!
    // written by the control side, read by the render thread (aligned 32/64-bit values: no tearing)
    let target = UnsafeMutablePointer<Float>.allocate(capacity: 1)   // 0 = programme, 1 = news
    let position = UnsafeMutablePointer<Float>.allocate(capacity: 1) // current fade position 0…1
    let underruns = UnsafeMutablePointer<Int>.allocate(capacity: 1)  // render cycles that came up short
    let playing = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)     // RMS of the last render cycle (before volume)

    public init() {
        target.pointee = 0; position.pointee = 0; underruns.pointee = 0; playing.pointee = false; level.pointee = 0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: DecoderCore.sampleRate, channels: 2)!
        let step = Float(1 / (Self.crossfadeSeconds * DecoderCore.sampleRate))
        let scratchP = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let scratchN = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let (prog, nws, tgt, pos, under, play, lvl) = (program, news, target, position, underruns, playing, level)
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let frames = min(Int(frameCount), 8192)
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            guard play.pointee else {
                prog.serviceClear(); nws.serviceClear()
                lvl.pointee = 0
                for i in 0..<frames { left[i] = 0; right[i] = 0 }
                return noErr
            }
            var x = pos.pointee
            let t = tgt.pointee
            let needN = t > 0 || x > 0
            let gotP = prog.tryRead(scratchP, frames * 2)
            let gotN = needN ? nws.tryRead(scratchN, frames * 2) : 0  // news ring only while it is heard
            if gotP < frames * 2 && (!needN || x < 1) { under.pointee += 1 }
            var sum: Float = 0
            for i in 0..<frames {
                if x < t { x = min(t, x + step) } else if x > t { x = max(t, x - step) }
                let gp = cosf(x * .pi / 2), gn = sinf(x * .pi / 2)
                let pL: Float = 2 * i < gotP ? scratchP[2 * i] : 0, pR: Float = 2 * i + 1 < gotP ? scratchP[2 * i + 1] : 0
                let nL: Float = 2 * i < gotN ? scratchN[2 * i] : 0, nR: Float = 2 * i + 1 < gotN ? scratchN[2 * i + 1] : 0
                left[i] = pL * gp + nL * gn
                right[i] = pR * gp + nR * gn
                sum += left[i] * left[i] + right[i] * right[i]
            }
            lvl.pointee = frames > 0 ? (sum / Float(frames * 2)).squareRoot() : 0
            pos.pointee = x
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    deinit { target.deallocate(); position.deallocate(); underruns.deallocate(); playing.deallocate(); level.deallocate() }

    public var underrunCount: Int { underruns.pointee }
    /// Loudness of what is playing right now (RMS, 0…1, before the volume slider) – drives the level bars.
    public var currentLevel: Float { level.pointee }
    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    public func start() throws { try engine.start() }
    public func stop() { playing.pointee = false; engine.stop() }
    public func setPlaying(_ on: Bool) { playing.pointee = on }
    /// Crossfade to the news ring (true) or back to the programme (false), 80 ms.
    public func showNews(_ on: Bool) { target.pointee = on ? 1 : 0 }
}
