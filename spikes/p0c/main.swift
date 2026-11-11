// P0-c spike: MPEG-TS → ADTS (own demuxer) → PCM (AudioFileStream + AVAudioConverter) for 1LIVE HLS segments.
// Usage: p0c <out.wav> <seg1.ts> [<seg2.ts> …]   – writes the decoded audio so it can be checked by ear/ffprobe.
import AVFoundation
import AudioToolbox

// ---- TS demux: PAT → PMT → first audio PID (0x0F ADTS / 0x03,0x04 MP3) → PES payloads ----
struct TsDemuxer {
    var pmtPID: Int?, audioPID: Int?, streamType = 0
    var pes = Data(), out = Data(), errors = 0

    mutating func feed(_ d: Data) {
        let b = [UInt8](d)
        var i = 0
        while i + 188 <= b.count {
            guard b[i] == 0x47 else { errors += 1; i += 1; continue }  // resync
            let p = Array(b[i..<i + 188]); i += 188
            let pusi = p[1] & 0x40 != 0, pid = Int(p[1] & 0x1F) << 8 | Int(p[2]), afc = (p[3] >> 4) & 3
            var off = 4
            if afc & 2 != 0 { off += 1 + Int(p[4]) }
            guard afc & 1 != 0, off < 188 else { continue }
            let payload = Array(p[off...])
            if pid == 0, pusi { parsePAT(payload) }
            else if pid == pmtPID, pusi { parsePMT(payload) }
            else if pid == audioPID {
                if pusi { flushPES(); pes = Data(payload) } else { pes.append(contentsOf: payload) }
            }
        }
    }
    mutating func flushPES() {
        let a = [UInt8](pes)
        guard a.count > 9, a[0] == 0, a[1] == 0, a[2] == 1 else { pes.removeAll(); return }
        let hdr = 9 + Int(a[8])
        if hdr < a.count { out.append(contentsOf: a[hdr...]) }
        pes.removeAll()
    }
    mutating func parsePAT(_ p: [UInt8]) {
        let s = 1 + Int(p[0])  // pointer field
        guard s + 12 <= p.count else { errors += 1; return }
        pmtPID = Int(p[s + 10] & 0x1F) << 8 | Int(p[s + 11])
    }
    mutating func parsePMT(_ p: [UInt8]) {
        let s = 1 + Int(p[0])
        guard s + 12 <= p.count else { errors += 1; return }
        let sectionLen = Int(p[s + 1] & 0x0F) << 8 | Int(p[s + 2])
        let progInfo = Int(p[s + 10] & 0x0F) << 8 | Int(p[s + 11])
        var j = s + 12 + progInfo
        let end = min(p.count, s + 3 + sectionLen - 4)
        while j + 5 <= end {
            let type = Int(p[j]), pid = Int(p[j + 1] & 0x1F) << 8 | Int(p[j + 2])
            let esLen = Int(p[j + 3] & 0x0F) << 8 | Int(p[j + 4])
            if [0x0F, 0x03, 0x04].contains(type), audioPID == nil { audioPID = pid; streamType = type }
            j += 5 + esLen
        }
    }
}

// ---- decode: AudioFileStream finds packets, AVAudioConverter makes Float PCM ----
final class Decoder {
    var stream: AudioFileStreamID?
    var asbd = AudioStreamBasicDescription()
    var converter: AVAudioConverter?
    var pcm: [AVAudioPCMBuffer] = []
    let outFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    var packets = 0

    init(type: AudioFileTypeID) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { ctx, s, prop, _ in
            let d = Unmanaged<Decoder>.fromOpaque(ctx).takeUnretainedValue()
            if prop == kAudioFileStreamProperty_DataFormat {
                var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                AudioFileStreamGetProperty(s, prop, &size, &d.asbd)
                let inFmt = AVAudioFormat(streamDescription: &d.asbd)!
                d.converter = AVAudioConverter(from: inFmt, to: d.outFormat)
            }
        }, { ctx, numBytes, numPackets, bytes, descs in
            let d = Unmanaged<Decoder>.fromOpaque(ctx).takeUnretainedValue()
            guard let conv = d.converter, let descs else { return }
            let inFmt = conv.inputFormat
            let comp = AVAudioCompressedBuffer(format: inFmt, packetCapacity: numPackets, maximumPacketSize: Int(numBytes))
            memcpy(comp.data, bytes, Int(numBytes))
            memcpy(comp.packetDescriptions!, descs, Int(numPackets) * MemoryLayout<AudioStreamPacketDescription>.size)
            comp.packetCount = numPackets; comp.byteLength = numBytes
            d.packets += Int(numPackets)
            let out = AVAudioPCMBuffer(pcmFormat: d.outFormat, frameCapacity: numPackets * 1024 * 2)!
            var given = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return comp
            }
            if let err { print("convert error", err) }
            if out.frameLength > 0 { d.pcm.append(out) }
        }, type, &stream)
    }
    func feed(_ d: Data) {
        d.withUnsafeBytes { p in _ = AudioFileStreamParseBytes(stream!, UInt32(d.count), p.baseAddress, []) }
    }
}

let args = CommandLine.arguments
var demux = TsDemuxer()
for f in args.dropFirst(2) { demux.feed(try! Data(contentsOf: URL(fileURLWithPath: f))) }
demux.flushPES()
print("TS: pmt=\(demux.pmtPID ?? -1) audioPID=\(demux.audioPID ?? -1) type=0x\(String(demux.streamType, radix: 16)) es=\(demux.out.count) B errors=\(demux.errors)")
let dec = Decoder(type: demux.streamType == 0x0F ? kAudioFileAAC_ADTSType : kAudioFileMP3Type)
dec.feed(demux.out)
let frames = dec.pcm.reduce(0) { $0 + Int($1.frameLength) }
print("decoded: format=\(dec.asbd.mSampleRate) Hz ch=\(dec.asbd.mChannelsPerFrame) fmt=\(dec.asbd.mFormatID) packets=\(dec.packets) pcmFrames=\(frames) = \(Double(frames) / 48000) s")
let file = try! AVAudioFile(forWriting: URL(fileURLWithPath: args[1]), settings: dec.outFormat.settings)
for b in dec.pcm { try! file.write(from: b) }
