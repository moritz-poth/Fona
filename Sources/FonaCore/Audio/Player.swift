import AVFoundation
import os

/// Ring buffer for interleaved stereo PCM between a decoding thread and the audio render thread.
/// The render side only ever *tries* the lock: it never waits, at worst it plays silence for one cycle.
public final class PCMRing: @unchecked Sendable {
    let capacity: Int  // in samples (frames × 2)
    let data: UnsafeMutablePointer<Float>
    var readPos = 0, count = 0
    var lock = os_unfair_lock()

    public init(seconds: Double) {
        capacity = Int(seconds * DecoderCore.sampleRate) * 2
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }
    deinit { data.deallocate() }

    public var fillSeconds: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return Double(count / 2) / DecoderCore.sampleRate
    }

    /// Writes as much as fits; returns the number of samples written. Copies in slices of ≤ 4096 samples with
    /// memcpy so the lock is held for microseconds only (the render thread must almost never find it taken).
    @discardableResult
    public func write(_ s: [Float]) -> Int {
        var done = 0
        s.withUnsafeBufferPointer { src in
            while done < src.count {
                os_unfair_lock_lock(&lock)
                let n = min(src.count - done, capacity - count, 4096)
                if n == 0 { os_unfair_lock_unlock(&lock); return }
                let w = (readPos + count) % capacity
                let first = min(n, capacity - w)
                (data + w).update(from: src.baseAddress! + done, count: first)
                if first < n { data.update(from: src.baseAddress! + done + first, count: n - first) }
                count += n
                os_unfair_lock_unlock(&lock)
                done += n
            }
        }
        return done
    }

    /// Render thread: copies up to `n` samples into `out`, returns how many; -1 if the lock stayed busy.
    /// Never blocks: retries `trylock` for a few microseconds (the writer holds it only for one ≤ 4096-sample memcpy);
    /// the soak test showed 3–7 misses per 30 min with a single try.
    func tryRead(_ out: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        var got = false
        for _ in 0..<2000 where !got { got = os_unfair_lock_trylock(&lock) }
        guard got else { return -1 }
        defer { os_unfair_lock_unlock(&lock) }
        let m = min(n, count)
        let first = min(m, capacity - readPos)
        out.update(from: data + readPos, count: first)
        if first < m { (out + first).update(from: data, count: m - first) }
        readPos = (readPos + m) % capacity
        count -= m
        return m
    }

    public func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        readPos = 0; count = 0
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
    let lockMisses = UnsafeMutablePointer<Int>.allocate(capacity: 1) // render cycles that found a ring locked
    let playing = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    public init() {
        target.pointee = 0; position.pointee = 0; underruns.pointee = 0; lockMisses.pointee = 0; playing.pointee = false
        let fmt = AVAudioFormat(standardFormatWithSampleRate: DecoderCore.sampleRate, channels: 2)!
        let step = Float(1 / (Self.crossfadeSeconds * DecoderCore.sampleRate))
        let scratchP = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let scratchN = UnsafeMutablePointer<Float>.allocate(capacity: 16384)
        let (prog, nws, tgt, pos, under, play, miss) = (program, news, target, position, underruns, playing, lockMisses)
        node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
            let frames = min(Int(frameCount), 8192)
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
            guard play.pointee else {
                for i in 0..<frames { left[i] = 0; right[i] = 0 }
                return noErr
            }
            var x = pos.pointee
            let t = tgt.pointee
            let needN = t > 0 || x > 0
            var gotP = prog.tryRead(scratchP, frames * 2)
            var gotN = needN ? nws.tryRead(scratchN, frames * 2) : 0  // news ring only while it is heard
            if gotP < 0 || gotN < 0 { miss.pointee += 1 }
            gotP = max(gotP, 0); gotN = max(gotN, 0)
            if gotP < frames * 2 && (!needN || x < 1) { under.pointee += 1 }
            for i in 0..<frames {
                if x < t { x = min(t, x + step) } else if x > t { x = max(t, x - step) }
                let gp = cosf(x * .pi / 2), gn = sinf(x * .pi / 2)
                let pL: Float = 2 * i < gotP ? scratchP[2 * i] : 0, pR: Float = 2 * i + 1 < gotP ? scratchP[2 * i + 1] : 0
                let nL: Float = 2 * i < gotN ? scratchN[2 * i] : 0, nR: Float = 2 * i + 1 < gotN ? scratchN[2 * i + 1] : 0
                left[i] = pL * gp + nL * gn
                right[i] = pR * gp + nR * gn
            }
            pos.pointee = x
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    deinit { target.deallocate(); position.deallocate(); underruns.deallocate(); lockMisses.deallocate(); playing.deallocate() }

    public var underrunCount: Int { underruns.pointee }
    public var lockMissCount: Int { lockMisses.pointee }
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
