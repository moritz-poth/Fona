import Foundation

/// Sink of the silent news chain: keeps the last 15 s of Deutschlandfunk, listens for the time signal and – while the
/// news is on air – forwards the audio into the player's news ring (PLAN §6.3).
final class NewsSink: PCMSink, @unchecked Sendable {
    static let historySeconds = 15.0
    let ring: PCMRing
    let detector = ToneDetector()
    let lock = NSLock()
    var history: [Float] = []
    var live = false
    var framesSeen = 0
    var onTone: (@Sendable (_ secondsAgo: Double) -> Void)?

    init(ring: PCMRing) { self.ring = ring }

    var bufferedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(history.count / 2) / DecoderCore.sampleRate }

    func reset() {
        lock.lock(); history.removeAll(); live = false; framesSeen = 0; lock.unlock()
        ring.clear()
    }

    func write(_ pcm: [Float]) async throws {
        lock.lock()
        history.append(contentsOf: pcm)
        let max = Int(Self.historySeconds * DecoderCore.sampleRate) * 2
        if history.count > max { history.removeFirst(history.count - max) }
        framesSeen += pcm.count / 2
        let seen = framesSeen
        let forward = live
        lock.unlock()
        if forward { ring.write(pcm) }  // real-time on both sides; a full ring drops (never blocks the network)
        for d in detector.feed(pcm) {
            onTone?(Double(seen - d.toneStartFrame) / DecoderCore.sampleRate)
        }
    }

    /// Starts forwarding: the last `seconds` of history first, then live.
    func activate(replaySeconds seconds: Double) {
        lock.lock()
        let n = min(history.count, Int(min(seconds, Self.historySeconds) * DecoderCore.sampleRate) * 2)
        let replay = Array(history.suffix(n))
        live = true
        lock.unlock()
        ring.clear()
        ring.write(replay)
    }

    func deactivate() {
        lock.lock(); live = false; lock.unlock()
    }
}

/// Runs the news switch: a second, silent Deutschlandfunk chain, time-signal and title detection, NewsLogic, crossfade.
/// All calls on the main thread.
@MainActor
public final class NewsWatcher {
    public static let newsURL = "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3"

    let player: Player
    let sink: NewsSink
    let station: StationPlayer
    var logic: NewsLogic
    var timer: Timer?
    public private(set) var active = false
    public var onActive: ((Bool) -> Void)?
    public var log: ((String) -> Void)?

    public init(player: Player, makeDecoder: @escaping @Sendable () -> FrameDecoder) {
        self.player = player
        sink = NewsSink(ring: player.news)
        station = StationPlayer(sink: sink, makeDecoder: makeDecoder)
        logic = NewsLogic()
        sink.onTone = { [weak self] ago in Task { @MainActor in self?.handle(.tone(secondsAgo: ago)) } }
        station.onTitle = { [weak self] t in Task { @MainActor in self?.handle(.title(t)) } }
        station.onState = { [weak self] s in
            if case .failed = s { Task { @MainActor in self?.handle(.newsStreamFailed) } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handle(.tick) }
        }
    }

    /// Is this programme Deutschlandfunk itself (then there is nothing to switch to)?
    public static func isNewsStation(_ url: String) -> Bool {
        let u = url.lowercased()
        return u.contains("dlf.de/dlf/") || u.contains("/ard/dlf/") || u.contains("deutschlandfunk.de") && !u.contains("kultur") && !u.contains("nova")
    }

    public func configure(halfHours: Bool, maxMinutes: Int) {
        logic.config.halfHours = halfHours
        logic.config.maxMinutes = Double(maxMinutes)
    }

    public func setEnabled(_ on: Bool) { handle(.setEnabled(on)) }
    public func program(playing: Bool, url: String?) {
        handle(.program(playing: playing, isNewsStation: url.map(Self.isNewsStation) ?? false))
    }
    public func backNow() { handle(.backNow) }

    func handle(_ e: NewsLogic.Event) {
        let actions = logic.handle(e, now: Date())
        for a in actions {
            log?("news \(a)")
            switch a {
            case .startNewsChain:
                station.play(Self.newsURL)
            case .stopNewsChain:
                station.stop()
            case .fadeToNews(let replay):
                sink.activate(replaySeconds: replay)
                player.showNews(true)
                setActive(true)
            case .fadeToProgram:
                player.showNews(false)
                setActive(false)
                // let the 80 ms fade finish before the news ring stops being filled
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.active else { return }
                    self.sink.deactivate()
                    self.player.news.clear()
                }
            }
        }
    }

    func setActive(_ on: Bool) {
        guard active != on else { return }
        active = on
        onActive?(on)
    }
}
