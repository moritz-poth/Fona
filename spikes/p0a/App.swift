// P0-a spike app: sandboxed (network.client only), ad-hoc signed.
// "--prepare": writes test data into its container, downloads the v2 zip from a local test server,
// starts the embedded updater helper and quits. Normal start: reads the test data and logs whether it survived.
import AppKit
import os

let version = SPIKE_VERSION
let log = Logger(subsystem: "fona.spike", category: "app")
let fm = FileManager.default
let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FonaSpike")
let data = support.appendingPathComponent("favorites.json")
let updates = support.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Updates")

log.notice("START version=\(version, privacy: .public) home=\(NSHomeDirectory(), privacy: .public)")
do {
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    if CommandLine.arguments.contains("--prepare") {
        try "favorites written by \(version)".write(to: data, atomically: true, encoding: .utf8)
        log.notice("WROTE favorites")
        try fm.createDirectory(at: updates, withIntermediateDirectories: true)
        let zip = try Data(contentsOf: URL(string: "http://127.0.0.1:8765/FonaSpike-v2.zip")!)
        let target = updates.appendingPathComponent("pending.zip")
        try? fm.removeItem(at: target)
        try zip.write(to: target)
        let q = (try? target.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        log.notice("DOWNLOADED \(zip.count) bytes to \(target.path, privacy: .public) quarantine=\(q != nil)")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FonaSpikeUpdater.app")
        // start the helper and quit right away: the helper waits until this process is gone
        NSWorkspace.shared.openApplication(at: helper, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { log.error("HELPER launch error=\(String(describing: err), privacy: .public)") }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    } else {
        let text = try String(contentsOf: data, encoding: .utf8)
        log.notice("READ OK: \(text, privacy: .public)")
    }
} catch {
    log.error("FAILED: \(String(describing: error), privacy: .public)")
}
exit(0)
