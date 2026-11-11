// P0-a spike helper: NOT sandboxed, hardened runtime, lives in FonaSpike.app/Contents/Helpers.
// Takes no arguments: finds the enclosing app from its own location, reads pending.zip from the app's container,
// unpacks it into a private temp dir, swaps the app (old one to the Trash), strips quarantine, relaunches.
import AppKit
import os

let log = Logger(subsystem: "fona.spike", category: "updater")
let fm = FileManager.default
let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let bundleID = "io.github.moritz-poth.fona.spike"
let zipURL = fm.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Updates/pending.zip")

func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
    try? p.run(); p.waitUntilExit(); return p.terminationStatus
}

log.notice("HELPER START app=\(appURL.path, privacy: .public)")
do {
    // wait for the app to quit (max 10 s)
    for _ in 0..<100 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
        usleep(100_000)
    }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
        log.error("HELPER app still running, giving up"); exit(1)
    }
    let zip = try Data(contentsOf: zipURL)
    log.notice("HELPER READ zip \(zip.count) bytes")
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fona-update-\(UUID().uuidString)")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    let local = tmp.appendingPathComponent("u.zip")
    try zip.write(to: local)
    let unzip = run("/usr/bin/ditto", ["-x", "-k", local.path, tmp.appendingPathComponent("x").path])
    let newApp = tmp.appendingPathComponent("x/FonaSpike.app")
    let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
    log.notice("HELPER unzip=\(unzip) verify=\(verify)")
    var trashed: NSURL?
    try fm.trashItem(at: appURL, resultingItemURL: &trashed)
    try fm.moveItem(at: newApp, to: appURL)
    let xattr = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
    log.notice("HELPER swapped, xattr=\(xattr)")
    try? fm.removeItem(at: tmp)
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { app, err in
        log.notice("HELPER relaunch app=\(app != nil) error=\(String(describing: err), privacy: .public)")
        sem.signal()
    }
    sem.wait()
} catch {
    log.error("HELPER FAILED: \(String(describing: error), privacy: .public)")
}
exit(0)
