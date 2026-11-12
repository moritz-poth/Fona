// Developer tool: fona-play <url> [seconds] [--mute]
// Plays one station through NetGate → StreamSource → DecoderCore → Player and prints titles and buffer health.
// shortcut: decodes in-process; the app decodes in the FonaDecoder XPC service (P2 step 2)
import Foundation
import FonaCore

let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
guard args.count >= 2 else { print("usage: fona-play <url> [seconds] [--mute]"); exit(2) }
let seconds = args.count > 2 ? Double(args[2]) ?? 60 : 60
let mute = CommandLine.arguments.contains("--mute")

let player = Player()
if mute { player.volume = 0 }
try player.start()
let t0 = Date()
var decoder: DecoderCore?
var frames = 0
var started = false

let reporter = Task {
    while true {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        print(String(format: "[%5.0fs] buffer %.1f s · underruns %d (lock %d) · decoded %.0f s · decode errors %d",
                     Date().timeIntervalSince(t0), player.program.fillSeconds, player.underrunCount, player.lockMissCount,
                     Double(frames) / DecoderCore.sampleRate, decoder?.errors ?? 0))
    }
}

do {
    let events = try await StreamSource.open(args[1])
    for try await e in events {
        switch e {
        case .format(let f):
            decoder = DecoderCore(format: f)
            print("format: \(f)")
        case .title(let t):
            print("title: \(t)")
        case .discontinuity:
            print("discontinuity")
        case .frames(let d):
            let pcm = decoder!.decode(d)
            frames += pcm.count / 2
            var rest = pcm[...]
            while !rest.isEmpty {  // back-pressure: wait while the ring is full
                let n = player.program.write(Array(rest))
                rest = rest.dropFirst(n)
                if !rest.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            if !started && player.program.fillSeconds >= 1.5 { player.setPlaying(true); started = true }
        }
        if Date().timeIntervalSince(t0) > seconds { break }
    }
    print(String(format: "END ok · %.0f s decoded · underruns %d · input %.0f Hz %d ch",
                 Double(frames) / DecoderCore.sampleRate, player.underrunCount,
                 decoder?.inputDescription.mSampleRate ?? 0, decoder?.inputDescription.mChannelsPerFrame ?? 0))
} catch let e as Rejection {
    print("REJECTED \(e.code): \(Messages.text(e, .de))")
} catch {
    print("ERROR \(error)")
}
reporter.cancel()
player.stop()
