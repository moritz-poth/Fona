// Fona – menu bar app. shortcut: P2 test shell (fixed stations, play/stop, title); the real UI comes in P4.
import SwiftUI
import FonaCore
import os

let log = Logger(subsystem: "io.github.moritz-poth.fona", category: "app")

@main
struct FonaApp: App {
    @StateObject private var radio = Radio()
    var body: some Scene {
        MenuBarExtra("Fona", systemImage: "radio") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Radio.testStations, id: \.name) { s in
                    Button(s.name) { radio.play(s) }
                }
                Divider()
                Text(verbatim: radio.status).font(.caption)
                Text(verbatim: radio.title).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Stop") { radio.stop() }
                    Button("Quit") { NSApp.terminate(nil) }
                }
            }
            .padding()
            .frame(width: 260)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Radio: ObservableObject {
    struct Station { let name: String; let url: String }
    static let testStations = [
        Station(name: "Deutschlandfunk", url: "https://st01.sslstream.dlf.de/dlf/01/128/mp3/stream.mp3"),
        Station(name: "radioeins", url: "https://www.radioeins.de/live.pls"),
        Station(name: "FluxFM", url: "https://streams.fluxfm.de/live/mp3-320/audio/"),
    ]

    @Published var status = "–"
    @Published var title = ""
    let player = Player()
    var task: Task<Void, Never>?

    init() {
        try? player.start()
        // developer launch arguments: --autoplay <index> [--mute] (P2 checks without clicking)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autoplay"), i + 1 < args.count, let n = Int(args[i + 1]), Radio.testStations.indices.contains(n) {
            if args.contains("--mute") { player.volume = 0 }
            play(Radio.testStations[n])
        }
    }

    func play(_ s: Station) {
        stop()
        status = "Verbinde mit \(s.name) …"
        let player = self.player
        task = Task.detached { [weak self] in
            let decoder = DecoderClient()
            defer { decoder.close() }
            do {
                for try await e in try await StreamSource.open(s.url) {
                    try Task.checkCancellation()
                    switch e {
                    case .format(let f):
                        let ok = decoder.open(f)
                        log.notice("format \(String(describing: f), privacy: .public) decoder service open=\(ok)")
                    case .title(let t): await MainActor.run { self?.title = t }
                    case .frames(let d):
                        let before = decoder.restarts
                        guard let pcm = decoder.decode(d) else { throw Rejection.notAudio }
                        if decoder.restarts != before { log.notice("decoder service restarted (\(decoder.restarts)), still playing") }
                        var rest = pcm[...]
                        while !rest.isEmpty {
                            let n = player.program.write(Array(rest))
                            rest = rest.dropFirst(n)
                            if !rest.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
                        }
                        if player.program.fillSeconds >= 1.5 {
                            if !(await MainActor.run { self?.status.hasPrefix("▶︎") ?? true }) {
                                log.notice("playing, buffer \(player.program.fillSeconds) s, service restarts \(decoder.restarts)")
                            }
                            player.setPlaying(true)
                            await MainActor.run { self?.status = "▶︎ \(s.name)" }
                        }
                    }
                }
            } catch is CancellationError {
            } catch let r as Rejection {
                log.error("stream ended: \(r.code, privacy: .public)")
                await MainActor.run { self?.status = Messages.text(r, .de) }
            } catch {
                await MainActor.run { self?.status = "Fehler: \(error)" }
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        player.setPlaying(false)
        player.program.clear()
        status = "–"; title = ""
    }
}
