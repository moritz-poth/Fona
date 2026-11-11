// P0-g spike: decoder XPC service, sandboxed without any entitlement (no network, no files).
import AVFoundation
import AudioToolbox
import os

let log = Logger(subsystem: "fona.spike", category: "decoder")

final class Decoder: NSObject, DecoderService {
    var stream: AudioFileStreamID?
    var asbd = AudioStreamBasicDescription()
    var converter: AVAudioConverter?
    var pending = Data()
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!

    override init() {
        super.init()
        let me = Unmanaged.passUnretained(self).toOpaque()
        AudioFileStreamOpen(me, { ctx, s, prop, _ in
            let d = Unmanaged<Decoder>.fromOpaque(ctx).takeUnretainedValue()
            guard prop == kAudioFileStreamProperty_DataFormat else { return }
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(s, prop, &size, &d.asbd)
            d.converter = AVAudioConverter(from: AVAudioFormat(streamDescription: &d.asbd)!, to: d.outFormat)
        }, { ctx, numBytes, numPackets, bytes, descs in
            let d = Unmanaged<Decoder>.fromOpaque(ctx).takeUnretainedValue()
            guard let conv = d.converter, let descs else { return }
            let comp = AVAudioCompressedBuffer(format: conv.inputFormat, packetCapacity: numPackets, maximumPacketSize: Int(numBytes))
            memcpy(comp.data, bytes, Int(numBytes))
            memcpy(comp.packetDescriptions!, descs, Int(numPackets) * MemoryLayout<AudioStreamPacketDescription>.size)
            comp.packetCount = numPackets; comp.byteLength = numBytes
            let out = AVAudioPCMBuffer(pcmFormat: d.outFormat, frameCapacity: numPackets * 2048)!
            var given = false
            conv.convert(to: out, error: nil) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true; status.pointee = .haveData; return comp
            }
            let bytesOut = Int(out.frameLength) * 8
            d.pending.append(Data(bytes: out.floatChannelData![0], count: bytesOut))
        }, kAudioFileAAC_ADTSType, &stream)
    }

    func decode(_ bytes: Data, reply: @escaping (Data) -> Void) {
        pending.removeAll(keepingCapacity: true)
        bytes.withUnsafeBytes { p in _ = AudioFileStreamParseBytes(stream!, UInt32(bytes.count), p.baseAddress, []) }
        reply(pending)
    }

    func crash() { log.notice("SERVICE crash requested"); abort() }

    func probeRights(reply: @escaping (String) -> Void) {
        let home = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) != nil ? "files=OPEN" : "files=blocked"
        let s = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: UInt16(443).bigEndian, sin_addr: in_addr(s_addr: inet_addr("1.1.1.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let err = errno
        close(s)
        reply("\(home) network=\(r == 0 ? "OPEN" : "blocked(errno \(err))")")
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: DecoderService.self)
        c.exportedObject = Decoder()
        c.resume()
        return true
    }
}

log.notice("SERVICE start pid=\(getpid())")
let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
