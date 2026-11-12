import Foundation
import Testing
@testable import FonaCore

final class Box: @unchecked Sendable { var values: [Double] = [] }

/// Regression for the crash of 2026-11-12: after a restart of the news chain the replay length came out negative.
@Test func replayLengthStaysValidAfterRestarts() async throws {
    let sink = NewsSink(ring: PCMRing(seconds: 20))
    let box = Box()
    sink.onTone = { box.values.append($0) }
    func feed(_ pcm: [Float]) async throws {
        var i = 0
        while i < pcm.count { let n = min(9600, pcm.count - i); try await sink.write(Array(pcm[i..<i + n])); i += n }
    }
    try await feed(TestMedia.music(seconds: 20))   // long run, then restart (station change before the fix)
    sink.reset()
    try await feed(TestMedia.music(seconds: 2) + TestMedia.timeSignal())
    #expect(box.values.count == 1)
    let ago = try #require(box.values.first)
    #expect(ago > 2.3 && ago < 3.6, "seconds since the first pip: \(ago)")
}

@Test func activateNeverCrashesOnBadLengths() async throws {
    let sink = NewsSink(ring: PCMRing(seconds: 20))
    try await sink.write(TestMedia.music(seconds: 1))
    for bad in [-133.6, -0.1, .infinity, -.infinity, .nan, 1e9] { sink.activate(replaySeconds: bad) }
    sink.deactivate()
}
