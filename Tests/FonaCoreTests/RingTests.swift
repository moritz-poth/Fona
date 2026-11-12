import Foundation
import Testing
@testable import FonaCore

/// Lock-free SPSC ring under real concurrency: every sample arrives once, in order.
@Test func ringKeepsOrderUnderConcurrency() async {
    let ring = PCMRing(seconds: 0.05)  // tiny ring → constant wrap-around and full/empty races
    let total = 2_000_000
    let producer = Thread {
        var next = 0
        while next < total {
            let chunk = (next..<min(total, next + 1 + Int.random(in: 0..<3000))).map { Float($0 % 16_777_216) }
            var rest = chunk[...]
            while !rest.isEmpty { let n = ring.write(Array(rest)); rest = rest.dropFirst(n) }
            next += chunk.count
        }
    }
    producer.start()
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    defer { buf.deallocate() }
    var expected = 0
    var ok = true
    let deadline = Date().addingTimeInterval(30)
    while expected < total && Date() < deadline {
        let n = ring.tryRead(buf, Int.random(in: 1...4096))
        for i in 0..<n where buf[i] != Float(expected + i) { ok = false }
        expected += n
        if !ok { break }
    }
    #expect(ok, "order broken near sample \(expected)")
    #expect(expected == total)
}

@Test func ringClearDropsBuffered() {
    let ring = PCMRing(seconds: 1)
    ring.write([Float](repeating: 1, count: 1000))
    ring.clear()
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: 10)
    defer { buf.deallocate() }
    #expect(ring.tryRead(buf, 10) == 0)
    ring.write([2, 3])
    #expect(ring.tryRead(buf, 10) == 2 && buf[0] == 2)
}
