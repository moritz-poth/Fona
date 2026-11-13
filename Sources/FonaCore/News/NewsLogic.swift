import Foundation

/// The news switch as a pure state machine (PLAN §6.3/§6.4). No audio, no network, no clock of its own:
/// the app feeds events with the current time and carries out the returned actions. Every row of the table is tested.
public struct NewsLogic: Sendable {
    public enum State: Equatable, Sendable { case off, ready, news(since: Date, titleSeen: Bool), cooldown(until: Date) }

    public enum Event: Equatable, Sendable {
        case setEnabled(Bool)
        /// The programme started (`isNewsStation`: the user listens to Deutschlandfunk itself) or stopped.
        case program(playing: Bool, isNewsStation: Bool)
        /// Time signal detected; `secondsAgo` = how long ago its first pip started (for the replay point).
        case tone(secondsAgo: Double)
        /// A (sanitized) title from the news station.
        case title(String)
        case tick
        case backNow
        case newsStreamFailed
    }

    public enum Action: Equatable, Sendable {
        case startNewsChain, stopNewsChain
        /// Crossfade to the news, replaying from this many seconds ago.
        case fadeToNews(replaySeconds: Double)
        case fadeToProgram
    }

    public struct Config: Sendable {
        public var halfHours = true
        public var windowSeconds = 90.0
        public var maxMinutes = 10.0
        public var hardMaxMinutes = 12.0
        public var cooldownMinutes = 10.0
        public var titleReplaySeconds = 4.0
        public var calendar = Calendar(identifier: .gregorian)
        public init() {}
    }

    public private(set) var state: State = .off
    var enabled = false
    var programPlaying = false
    var programIsNews = false
    /// nil = no title seen since the news chain started: the first one only sets the baseline (never triggers).
    var lastTitleMatched: Bool?
    public var config: Config

    public init(config: Config = Config()) { self.config = config }

    /// `^Nachrichten\b`, case-insensitive (not "Nachrichtenleicht", "Sport-Nachrichten", "Wie Nachrichten entstehen").
    public static func isNewsTitle(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespaces).lowercased()
        guard s.hasPrefix("nachrichten") else { return false }
        let rest = s.dropFirst("nachrichten".count)
        return rest.first.map { !$0.isLetter && !$0.isNumber } ?? true
    }

    /// "Deutschlandfunk", "Deutschlandfunk - Alles von Relevanz": the filler title DLF shows when a slot has no own title.
    public static func isStationName(_ t: String) -> Bool {
        t.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("deutschlandfunk")
    }

    /// Inside ±window around :00 (and :30 with half hours)?
    public func inScheduleWindow(_ now: Date) -> Bool {
        let c = config.calendar.dateComponents([.minute, .second], from: now)
        let secOfHour = Double((c.minute ?? 0) * 60 + (c.second ?? 0))
        let marks: [Double] = config.halfHours ? [0, 1800, 3600] : [0, 3600]
        return marks.contains { abs(secOfHour - $0) <= config.windowSeconds }
    }

    var shouldWatch: Bool { enabled && programPlaying && !programIsNews }

    public mutating func handle(_ e: Event, now: Date) -> [Action] {
        switch (state, e) {
        case (_, .setEnabled(let on)):
            enabled = on
            return reconcile(now)
        case (_, .program(let playing, let isNews)):
            programPlaying = playing; programIsNews = isNews
            if case .news = state, isNews && playing { state = .off; return [.stopNewsChain] }  // news became the programme
            return reconcile(now)

        case (.ready, .tone(let ago)) where inScheduleWindow(now):
            state = .news(since: now, titleSeen: lastTitleMatched == true)
            return [.fadeToNews(replaySeconds: ago)]
        case (.ready, .title(let t)):
            let matched = Self.isNewsTitle(t)
            defer { lastTitleMatched = matched }
            // a title only starts the news inside the window, and only when it *changes* to news (not mid-programme)
            if matched && lastTitleMatched == false && inScheduleWindow(now) {
                state = .news(since: now, titleSeen: true)
                return [.fadeToNews(replaySeconds: config.titleReplaySeconds)]
            }
            return []

        case (.news(let since, _), .title(let t)):
            let matched = Self.isNewsTitle(t)
            lastTitleMatched = matched
            if matched { state = .news(since: since, titleSeen: true); return [] }
            // without a news title in this episode (09:00/00:00 in P0-b) only the bare station name is "still news";
            // the first real programme title ends it
            if case .news(_, true) = state { return endNews(now) }
            return Self.isStationName(t) ? [] : endNews(now)
        case (.news(let since, let seen), .tick):
            let limit = seen ? config.hardMaxMinutes : config.maxMinutes
            return now.timeIntervalSince(since) >= limit * 60 ? endNews(now) : []
        case (.news, .backNow), (.news, .newsStreamFailed):
            return endNews(now)
        case (.news, .tone):
            return []  // already on the news

        case (.cooldown(let until), .tick) where now >= until:
            state = .ready
            return []
        case (_, .title(let t)):
            lastTitleMatched = Self.isNewsTitle(t)
            return []
        default:
            return []
        }
    }

    mutating func endNews(_ now: Date) -> [Action] {
        state = .cooldown(until: now.addingTimeInterval(config.cooldownMinutes * 60))
        return [.fadeToProgram]
    }

    /// Starts or stops watching when the conditions change.
    mutating func reconcile(_ now: Date) -> [Action] {
        switch (state, shouldWatch) {
        case (.off, true):
            state = .ready
            lastTitleMatched = nil
            return [.startNewsChain]
        case (.off, false):
            return []
        case (.news, false):
            state = .off
            return [.fadeToProgram, .stopNewsChain]
        case (_, false):
            state = .off
            return [.stopNewsChain]
        default:
            return []
        }
    }
}
