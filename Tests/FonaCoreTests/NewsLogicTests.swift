import Foundation
import Testing
@testable import FonaCore

/// Every row of PLAN §6.4 with a simulated clock.
struct Clock {
    var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Berlin")!; return c }()
    func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: h, minute: m, second: s))! }
}

func logic(enabled: Bool = true, playing: Bool = true) -> (NewsLogic, Clock) {
    let clock = Clock()
    var cfg = NewsLogic.Config(); cfg.calendar = clock.cal
    var l = NewsLogic(config: cfg)
    _ = l.handle(.setEnabled(enabled), now: clock.at(11, 50))
    _ = l.handle(.program(playing: playing, isNewsStation: false), now: clock.at(11, 50))
    return (l, clock)
}

@Test func watchingStartsOnlyWhenEnabledAndPlaying() {
    let c = Clock()
    var l = NewsLogic(config: { var x = NewsLogic.Config(); x.calendar = c.cal; return x }())
    #expect(l.handle(.program(playing: true, isNewsStation: false), now: c.at(11, 0)) == [])
    #expect(l.handle(.setEnabled(true), now: c.at(11, 0)) == [.startNewsChain])
    #expect(l.state == .ready)
    #expect(l.handle(.program(playing: false, isNewsStation: false), now: c.at(11, 1)) == [.stopNewsChain])  // pause
    #expect(l.state == .off)
    #expect(l.handle(.program(playing: true, isNewsStation: true), now: c.at(11, 2)) == [])  // listening to DLF itself
    #expect(l.state == .off)
}

@Test func toneInWindowSwitchesAndTitlelessNewsEndsByDuration() {
    var (l, c) = logic()
    #expect(l.handle(.tone(secondsAgo: 2.5), now: c.at(12, 0, 3)) == [.fadeToNews(replaySeconds: 2.5)])
    // 09:00/00:00 case: the title never says "Nachrichten" → the bare station name must NOT end the news
    #expect(l.handle(.title("Deutschlandfunk - Alles von Relevanz"), now: c.at(12, 0, 30)) == [])
    #expect(l.handle(.title("Deutschlandfunk"), now: c.at(12, 0, 45)) == [])
    #expect(l.handle(.tick, now: c.at(12, 9)) == [])
    #expect(l.handle(.tick, now: c.at(12, 10, 4)) == [.fadeToProgram])  // maxMinutes 10
    #expect(l.handle(.tone(secondsAgo: 1), now: c.at(12, 10, 30)) == [])  // cooldown
    #expect(l.handle(.tick, now: c.at(12, 20, 4)) == [])
    #expect(l.state == .ready)
}

@Test func toneOutsideWindowIsIgnored() {
    var (l, c) = logic()
    #expect(l.handle(.tone(secondsAgo: 2), now: c.at(12, 14)) == [])
    #expect(l.state == .ready)
}

@Test func newsTitleEndsNewsAfterItWasSeen() {
    var (l, c) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(11, 30, 2))
    #expect(l.handle(.title("Nachrichten, Deutschlandfunk-Nachrichtenredaktion"), now: c.at(11, 30, 4)) == [])
    #expect(l.handle(.title("Nachrichten"), now: c.at(11, 31)) == [])
    #expect(l.handle(.title("Deutschlandfunk"), now: c.at(11, 35, 5)) == [.fadeToProgram])
}

@Test func titleStartsNewsOnlyOnChangeInsideWindow() {
    var (l, c) = logic()
    _ = l.handle(.title("Musik"), now: c.at(11, 13))                                    // baseline
    #expect(l.handle(.title("Nachrichten"), now: c.at(11, 14)) == [])                  // outside window
    #expect(l.handle(.title("Musik"), now: c.at(11, 59)) == [])
    #expect(l.handle(.title("Nachrichten"), now: c.at(12, 0, 4)) == [.fadeToNews(replaySeconds: 4)])
}

@Test func titleAlreadyNewsAtStartDoesNotTrigger() {
    var (l, c) = logic(playing: false)
    _ = l.handle(.title("Nachrichten"), now: c.at(12, 2))           // watcher sees the middle of a bulletin
    _ = l.handle(.program(playing: true, isNewsStation: false), now: c.at(12, 2))
    #expect(l.handle(.title("Nachrichten"), now: c.at(12, 2, 20)) == [])
}

@Test func backNowAndFailureAndHardLimit() {
    var (l, c) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    #expect(l.handle(.backNow, now: c.at(12, 1)) == [.fadeToProgram])
    if case .cooldown = l.state {} else { Issue.record("expected cooldown") }

    (l, _) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    #expect(l.handle(.newsStreamFailed, now: c.at(12, 0, 30)) == [.fadeToProgram])

    (l, _) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    _ = l.handle(.title("Nachrichten"), now: c.at(12, 0, 5))  // title seen → title decides, hard limit 12 min
    #expect(l.handle(.tick, now: c.at(12, 7)) == [])
    #expect(l.handle(.tick, now: c.at(12, 12, 3)) == [.fadeToProgram])
}

@Test func pauseOrDisableDuringNews() {
    var (l, c) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    #expect(l.handle(.setEnabled(false), now: c.at(12, 1)) == [.fadeToProgram, .stopNewsChain])
    (l, _) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    #expect(l.handle(.program(playing: false, isNewsStation: false), now: c.at(12, 1)) == [.fadeToProgram, .stopNewsChain])
    (l, _) = logic()
    _ = l.handle(.tone(secondsAgo: 2), now: c.at(12, 0, 2))
    #expect(l.handle(.program(playing: true, isNewsStation: true), now: c.at(12, 1)) == [.stopNewsChain])  // user picked DLF
}

@Test(arguments: [("Nachrichten", true), ("Nachrichten, Deutschlandfunk-Nachrichtenredaktion", true), ("NACHRICHTEN", true),
                  ("Nachrichtenleicht", false), ("Sport-Nachrichten", false), ("Wie Nachrichten entstehen", false), ("", false)])
func newsTitleRule(_ t: String, _ expected: Bool) { #expect(NewsLogic.isNewsTitle(t) == expected) }

@Test func halfHourWindow() {
    let c = Clock()
    var cfg = NewsLogic.Config(); cfg.calendar = c.cal
    var l = NewsLogic(config: cfg)
    #expect(l.inScheduleWindow(c.at(11, 30, 50)))
    #expect(l.inScheduleWindow(c.at(11, 58, 40)))
    #expect(!l.inScheduleWindow(c.at(11, 45)))
    l.config.halfHours = false
    #expect(!l.inScheduleWindow(c.at(11, 30, 50)))
}

@Test func firstTitleAfterChainStartIsOnlyTheBaseline() {
    var (l, c) = logic()  // chain just started at 11:50
    #expect(l.handle(.title("Nachrichten"), now: c.at(12, 0, 20)) == [])   // joined mid-bulletin: stay
    #expect(l.handle(.title("Musik"), now: c.at(12, 5)) == [])
    #expect(l.handle(.title("Nachrichten"), now: c.at(12, 30, 3)) == [.fadeToNews(replaySeconds: 4)])
}

@Test func titlelessNewsEndsAtFirstProgrammeTitle() {
    var (l, c) = logic()
    #expect(l.handle(.tone(secondsAgo: 2), now: c.at(9, 0, 1)) == [.fadeToNews(replaySeconds: 2)])
    #expect(l.handle(.title("Deutschlandfunk"), now: c.at(9, 0, 25)) == [])
    #expect(l.handle(.title("Vor 15 Jahren: Silvio Berlusconi tritt zurück"), now: c.at(9, 5, 17)) == [.fadeToProgram])
    if case .cooldown = l.state {} else { Issue.record("expected cooldown, got \(l.state)") }
}
