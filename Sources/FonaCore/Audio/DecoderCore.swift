import AVFoundation
import AudioToolbox

/// Compressed frames → PCM (Float32, 48 kHz, stereo, interleaved). Runs inside the FonaDecoder XPC service in the app;
/// tests and the developer tools use it directly. Input must come from `FrameGuard` (PLAN S5).
public final class DecoderCore {
    public static let sampleRate = 48_000.0
    public static let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true)!

    let fileType: AudioFileTypeID
    var stream: AudioFileStreamID?
    var converter: AVAudioConverter?
    var output = [Float]()
    public private(set) var inputDescription = AudioStreamBasicDescription()
    public private(set) var errors = 0

    public init(format: FrameGuard.Format) {
        fileType = format == .adts ? kAudioFileAAC_ADTSType : kAudioFileMP3Type
        open()
    }

    deinit { if let stream { AudioFileStreamClose(stream) } }

    func open() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { ctx, s, prop, _ in
            Unmanaged<DecoderCore>.fromOpaque(ctx).takeUnretainedValue().property(s, prop)
        }, { ctx, numBytes, numPackets, bytes, descs in
            Unmanaged<DecoderCore>.fromOpaque(ctx).takeUnretainedValue().packets(numBytes, numPackets, bytes, descs)
        }, fileType, &stream)
    }

    /// Format changes mid-stream or HLS discontinuities: start over with a fresh parser and converter.
    public func reset() {
        if let stream { AudioFileStreamClose(stream) }
        stream = nil; converter = nil
        open()
    }

    /// Feeds whole frames, returns the PCM they produced (interleaved L R L R …).
    public func decode(_ frames: Data) -> [Float] {
        output.removeAll(keepingCapacity: true)
        guard let stream, !frames.isEmpty else { return [] }
        let status = frames.withUnsafeBytes { AudioFileStreamParseBytes(stream, UInt32(frames.count), $0.baseAddress, []) }
        if status != noErr { errors += 1 }
        return output
    }

    func property(_ s: AudioFileStreamID, _ prop: AudioFileStreamPropertyID) {
        guard prop == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileStreamGetProperty(s, kAudioFileStreamProperty_DataFormat, &size, &asbd)
        // HE-AAC: the plain data format reports AAC-LC at half the rate; the format list holds the real one (PLAN M8)
        var listSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(s, kAudioFileStreamProperty_FormatList, &listSize, nil) == noErr, listSize > 0 {
            let n = Int(listSize) / MemoryLayout<AudioFormatListItem>.size
            var list = [AudioFormatListItem](repeating: AudioFormatListItem(), count: n)
            if AudioFileStreamGetProperty(s, kAudioFileStreamProperty_FormatList, &listSize, &list) == noErr, let best = list.first {
                asbd = best.mASBD
            }
        }
        inputDescription = asbd
        guard asbd.mChannelsPerFrame >= 1, asbd.mChannelsPerFrame <= 2, asbd.mSampleRate >= 8000, asbd.mSampleRate <= 96_000,
              let inFmt = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: inFmt, to: Self.outFormat) else { errors += 1; return }
        if asbd.mChannelsPerFrame == 1 { conv.channelMap = [0, 0] }  // mono on both speakers
        converter = conv
    }

    func packets(_ numBytes: UInt32, _ numPackets: UInt32, _ bytes: UnsafeRawPointer, _ descs: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let conv = converter, let descs, numPackets > 0 else { return }
        let comp = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: numPackets, maximumPacketSize: Int(numBytes))
        memcpy(comp.data, bytes, Int(numBytes))
        memcpy(comp.packetDescriptions!, descs, Int(numPackets) * MemoryLayout<AudioStreamPacketDescription>.size)
        comp.packetCount = numPackets
        comp.byteLength = numBytes
        // generous capacity: 2048 samples per packet (HE-AAC) at up to 2× resampling
        let cap = AVAudioFrameCount(numPackets) * 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: cap) else { return }
        var given = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true; st.pointee = .haveData; return comp
        }
        if status == .error { errors += 1; return }
        let n = Int(out.frameLength) * 2
        output.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
    }
}
