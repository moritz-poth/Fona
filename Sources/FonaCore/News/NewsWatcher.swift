import Foundation

/// Sink of the silent news chain: keeps the last 15 s of Deutschlandfunk, listens for the time signal and – while the
/// news is on air – forwards the audio into the player's news ring (PLAN §6.3).
final class NewsSink: PCMSink, @unchecked Sendable {
    static let historySeconds = 15.0
    let ring: PCMRing
    var detector = ToneDetector()
    let lock = NSLock()
    var history: [Float] = []
    var live = false
    var onTone: (@Sendable (_ secondsAgo: Double) -> Void)?

    init(ring: PCMRing) { self.ring = ring }

    var bufferedSeconds: Double { lock.lock(); defer { lock.unlock() }; return Double(history.count / 2) / DecoderCore.sampleRate }

    func reset() {
        lock.lock(); history.removeAll(); live = false; detector = ToneDetector(); lock.unlock()
        ring.clear()
    }

    func write(_ pcm: [Float]) async throws {
        lock.lock()
        history.append(contentsOf: pcm)
        let max = Int(Self.historySeconds * DecoderCore.sampleRate) * 2
        if history.count > max { history.removeFirst(history.count - max) }
        let forward = live
        let det = detector
        lock.unlock()
        if forward { ring.write(pcm) }  // real-time on both sides; a full ring drops (never blocks the network)
        // seconds since the first pip, from the detector's own frame counter (2026-11-12 crash: two counters drifted
        // apart after a restart of the chain and gave a negative replay length)
        for d in det.feed(pcm) {
            onTone?(Double(det.framesSeen - d.toneStartFrame) / DecoderCore.sampleRate)
        }
    }

    /// Starts forwarding: the last `seconds` of history first, then live.
    func activate(replaySeconds seconds: Double) {
        let safe = seconds.isFinite ? Swift.min(Swift.max(seconds, 0), Self.historySeconds) : 0
        lock.lock()
        let n = Swift.max(0, Swift.min(history.count, Int(safe * DecoderCore.sampleRate) * 2))
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
    /// Extra seconds replayed before the time signal, so the switch never lands right on the first pip.
    public static let leadInSeconds = 1.5

    let player: Player
    let sink: NewsSink
    let station: StationPlayer
    var logic: NewsLogic
    var timer: Timer?
    public private(set) var active = false
    public var onActive: ((Bool) -> Void)?
    /// The bulletin still runs after „Back now“ (banner with „To the news“).
    public private(set) var skipped = false
    public var onSkipped: ((Bool) -> Void)?
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
    public func rejoin() { handle(.rejoin) }

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
                // start a little before the first pip (user: "very tight") – the history holds 15 s
                sink.activate(replaySeconds: replay + Self.leadInSeconds)
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
        if logic.state.isSkipped != skipped { skipped.toggle(); onSkipped?(skipped) }
    }

    func setActive(_ on: Bool) {
        guard active != on else { return }
        active = on
        onActive?(on)
    }
}
