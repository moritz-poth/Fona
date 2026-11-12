import Foundation

/// Turns compressed frames into PCM. The app uses the XPC service (`DecoderClient`), tools decode in-process.
public protocol FrameDecoder: AnyObject, Sendable {
    func start(_ format: FrameGuard.Format) -> Bool
    /// nil = decoder broken (the stream is ended).
    func pcm(_ frames: Data) -> [Float]?
    func stop()
}

extension DecoderClient: FrameDecoder {
    public func start(_ format: FrameGuard.Format) -> Bool { open(format) }
    public func pcm(_ frames: Data) -> [Float]? { decode(frames) }
    public func stop() { close() }
}

public final class InProcessDecoder: FrameDecoder, @unchecked Sendable {
    var core: DecoderCore?
    public init() {}
    public func start(_ format: FrameGuard.Format) -> Bool { core = DecoderCore(format: format); return true }
    public func pcm(_ frames: Data) -> [Float]? { core?.decode(frames) }
    public func stop() { core = nil }
}

/// One station feeding one ring: connect, decode, write, and reconnect after network trouble
/// (PLAN §5: after 1, 2, 5, 10, 10 s, then give up). Refusals (wrong format, home network, …) are never retried.
public final class StationPlayer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case connecting, buffering, playing
        case reconnecting(attempt: Int)
        case failed(Rejection)
        case stopped
    }

    public typealias Opener = @Sendable (String) async throws -> AsyncThrowingStream<StreamEvent, Error>
    public static let defaultRetryDelays: [Double] = [1, 2, 5, 10, 10]
    public static let startBufferSeconds = 1.5

    let ring: PCMRing
    let makeDecoder: @Sendable () -> FrameDecoder
    let opener: Opener
    let retryDelays: [Double]
    var task: Task<Void, Never>?
    public var onState: (@Sendable (State) -> Void)?
    public var onTitle: (@Sendable (String) -> Void)?

    public init(ring: PCMRing, retryDelays: [Double] = StationPlayer.defaultRetryDelays,
                opener: @escaping Opener = { try await StreamSource.open($0) },
                makeDecoder: @escaping @Sendable () -> FrameDecoder) {
        self.ring = ring
        self.retryDelays = retryDelays
        self.opener = opener
        self.makeDecoder = makeDecoder
    }

    /// Network-type problems are worth another try; everything else is a property of the link.
    public static func isRetryable(_ e: Error) -> Bool {
        guard let r = e as? Rejection else { return !(e is CancellationError) }
        switch r {
        case .network, .stalled, .tooSlow, .connectTimeout, .headerTimeout, .noAddress: return true
        case .httpStatus(let c): return c >= 500
        default: return false
        }
    }

    public func play(_ url: String) {
        stop()
        task = Task.detached { [weak self] in await self?.run(url) }
    }

    public func stop() {
        task?.cancel()
        task = nil
        ring.clear()
    }

    func run(_ url: String) async {
        var attempt = 0
        while !Task.isCancelled {
            onState?(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            let decoder = makeDecoder()
            var gotAudio = false
            do {
                var buffering = true
                for try await e in try await opener(url) {
                    try Task.checkCancellation()
                    switch e {
                    case .format(let f):
                        guard decoder.start(f) else { throw Rejection.notAudio }
                        onState?(.buffering)
                    case .title(let t):
                        onTitle?(t)
                    case .discontinuity:
                        decoder.stop()  // the following .format event starts it again
                    case .frames(let d):
                        guard let pcm = decoder.pcm(d) else { throw Rejection.notAudio }
                        try await write(pcm)
                        gotAudio = true
                        if buffering, ring.fillSeconds >= Self.startBufferSeconds {
                            buffering = false
                            attempt = 0
                            onState?(.playing)
                        }
                    }
                }
                throw Rejection.stalled  // the server closed an endless stream
            } catch is CancellationError {
                decoder.stop()
                return
            } catch {
                decoder.stop()
                if Task.isCancelled { return }
                if gotAudio { attempt = 0 }
                guard Self.isRetryable(error), attempt < retryDelays.count else {
                    onState?(.failed(error as? Rejection ?? .network))
                    return
                }
                let delay = retryDelays[attempt]
                attempt += 1
                onState?(.reconnecting(attempt: attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Back-pressure: waits while the ring is full.
    func write(_ pcm: [Float]) async throws {
        var rest = pcm[...]
        while !rest.isEmpty {
            let n = ring.write(Array(rest))
            rest = rest.dropFirst(n)
            if !rest.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        }
    }
}
