import Foundation
import Testing
@testable import FonaCore

/// Decoder stand-in: every frame byte becomes 1 000 stereo samples, so the ring fills quickly.
final class FakeDecoder: FrameDecoder, @unchecked Sendable {
    func start(_ format: FrameGuard.Format) -> Bool { true }
    func pcm(_ frames: Data) -> [Float]? { [Float](repeating: 0.1, count: frames.count * 2000) }
    func stop() {}
}

final class StateLog: @unchecked Sendable {
    let lock = NSLock()
    var states: [StationPlayer.State] = []
    func add(_ s: StationPlayer.State) { lock.lock(); states.append(s); lock.unlock() }
    var all: [StationPlayer.State] { lock.lock(); defer { lock.unlock() }; return states }
}

func waitFor(_ cond: () -> Bool, seconds: Double = 5) async {
    let end = Date().addingTimeInterval(seconds)
    while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
}

@Test func reconnectsAfterNetworkErrors() async {
    let attempts = StateLog()  // reuse as counter
    let opener: StationPlayer.Opener = { _ in
        attempts.add(.connecting)
        if attempts.all.count <= 2 { throw Rejection.network }
        return AsyncThrowingStream { c in
            c.yield(.format(.mp3)); c.yield(.title("T"))
            for _ in 0..<50 { c.yield(.frames(Data(count: 100))) }
        }
    }
    let log = StateLog()
    let p = StationPlayer(ring: PCMRing(seconds: 20), retryDelays: [0.01, 0.01, 0.01], opener: opener) { FakeDecoder() }
    p.onState = { log.add($0) }
    p.play("https://radio.example.com/")
    await waitFor { log.all.contains(.playing) }
    p.stop()
    #expect(log.all.contains(.reconnecting(attempt: 1)))
    #expect(log.all.contains(.reconnecting(attempt: 2)))
    #expect(log.all.contains(.playing))
}

@Test func givesUpAfterFiveTries() async {
    let log = StateLog()
    let p = StationPlayer(ring: PCMRing(seconds: 1), retryDelays: [0.01, 0.01, 0.01, 0.01, 0.01],
                          opener: { _ in throw Rejection.stalled }) { FakeDecoder() }
    p.onState = { log.add($0) }
    p.play("https://radio.example.com/")
    await waitFor { log.all.contains(.failed(.stalled)) }
    #expect(log.all.contains(.failed(.stalled)))
    #expect(log.all.filter { if case .reconnecting = $0 { return true } else { return false } }.count >= 5)
}

@Test(arguments: [Rejection.privateAddress, .notAudio, .blockedContentType, .tls, .httpStatus(404)])
func refusalIsNotRetried(_ r: Rejection) async {
    let log = StateLog()
    let p = StationPlayer(ring: PCMRing(seconds: 1), retryDelays: [0.01], opener: { _ in throw r }) { FakeDecoder() }
    p.onState = { log.add($0) }
    p.play("https://radio.example.com/")
    await waitFor { log.all.contains(.failed(r)) }
    #expect(log.all == [.connecting, .failed(r)])
}
