// P0-g spike host: sandboxed app that decodes test ADTS through the decoder XPC service,
// measures latency per call, checks the service's rights and restarts it after a crash.
import Foundation
import os

let log = Logger(subsystem: "fona.spike", category: "host")

func makeConnection() -> NSXPCConnection {
    let c = NSXPCConnection(serviceName: decoderServiceName)
    c.remoteObjectInterface = NSXPCInterface(with: DecoderService.self)
    c.interruptionHandler = { log.notice("HOST service interrupted") }
    c.resume()
    return c
}

func proxy(_ c: NSXPCConnection) -> DecoderService {
    c.synchronousRemoteObjectProxyWithErrorHandler { e in log.error("HOST xpc error \(String(describing: e), privacy: .public)") } as! DecoderService
}

func decodeAll(_ c: NSXPCConnection, _ data: Data, label: String) {
    let chunk = 16_384
    var frames = 0, worst = 0.0, total = 0.0, calls = 0
    var i = 0
    while i < data.count {
        let piece = data.subdata(in: i..<min(i + chunk, data.count)); i += chunk
        let t0 = Date()
        proxy(c).decode(piece) { pcm in frames += pcm.count / 8 }
        let ms = Date().timeIntervalSince(t0) * 1000
        worst = max(worst, ms); total += ms; calls += 1
    }
    log.notice("HOST \(label, privacy: .public): calls=\(calls) pcmFrames=\(frames) (\(Double(frames) / 48000, format: .fixed(precision: 2)) s) avg=\(total / Double(calls), format: .fixed(precision: 2)) ms worst=\(worst, format: .fixed(precision: 2)) ms")
}

let data = try! Data(contentsOf: Bundle.main.url(forResource: "test", withExtension: "adts")!)
var conn = makeConnection()
decodeAll(conn, data, label: "run1")
proxy(conn).probeRights { log.notice("HOST service rights: \($0, privacy: .public)") }
proxy(conn).crash()
usleep(300_000)
// the same connection re-launches the service on the next call after an interruption
decodeAll(conn, data, label: "after-crash")
conn.invalidate()
exit(0)
