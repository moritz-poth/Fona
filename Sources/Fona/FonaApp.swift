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
    lazy var station = StationPlayer(ring: player.program) { DecoderClient() }
    var current = ""

    init() {
        try? player.start()
        station.onState = { [weak self] s in Task { @MainActor in self?.show(s) } }
        station.onTitle = { [weak self] t in Task { @MainActor in self?.title = t } }
        // developer launch arguments: --autoplay <index> [--mute] (checks without clicking)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autoplay"), i + 1 < args.count, let n = Int(args[i + 1]), Radio.testStations.indices.contains(n) {
            if args.contains("--mute") { player.volume = 0 }
            play(Radio.testStations[n])
        }
    }

    func play(_ s: Station) {
        current = s.name
        title = ""
        player.setPlaying(false)
        station.play(s.url)
    }

    func stop() {
        station.stop()
        player.setPlaying(false)
        status = "–"; title = ""
    }

    func show(_ s: StationPlayer.State) {
        log.notice("state \(String(describing: s), privacy: .public)")
        switch s {
        case .connecting: status = "Verbinde mit \(current) …"
        case .buffering: status = "Puffere \(current) …"
        case .playing: player.setPlaying(true); status = "▶︎ \(current)"
        case .reconnecting(let n): status = "Verbindung verloren – neuer Versuch \(n) von \(StationPlayer.defaultRetryDelays.count)"
        case .failed(let r): player.setPlaying(false); status = Messages.text(r, .de)
        case .stopped: status = "–"
        }
    }
}
