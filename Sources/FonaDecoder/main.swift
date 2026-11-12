// FonaDecoder XPC service: sandboxed without any entitlement (no network, no files). Bytes in, PCM out.
import Foundation
import FonaCore

final class Service: NSObject, FonaDecoderProtocol {
    var guardian: FrameGuard?
    var core: DecoderCore?

    func open(format: Int, reply: @escaping (Bool) -> Void) {
        let f: FrameGuard.Format = format == 0 ? .mp3 : .adts
        guardian = FrameGuard(format: f)
        core = DecoderCore(format: f)
        reply(true)
    }

    func decode(_ bytes: Data, reply: @escaping (Data, Bool) -> Void) {
        guard var g = guardian, let core, bytes.count <= 1_048_576 else { reply(Data(), false); return }
        do {
            let frames = try g.feed(bytes)  // second wall: only whole valid frames reach Apple's decoder
            guardian = g
            let pcm = core.decode(frames)
            reply(pcm.withUnsafeBufferPointer { Data(buffer: $0) }, true)
        } catch {
            reply(Data(), false)
        }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: FonaDecoderProtocol.self)
        c.exportedObject = Service()  // one decoder per connection
        c.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
