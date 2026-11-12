// FonaUpdater – the trust boundary of updates (PLAN §7, review H1). Not sandboxed, hardened runtime, lives in
// Fona.app/Contents/Helpers/FonaUpdater.app and is started by Fona with NSWorkspace.openApplication.
// Takes NO arguments and ignores the environment: the target is the app around it, the download sits under a fixed
// name in Fona's container. Everything is verified here again – the checks in Fona only produce clear messages.
import AppKit
import FonaCore
import os

let log = Logger(subsystem: "io.github.moritz-poth.fona", category: "updater")
let fm = FileManager.default
let bundleID = "io.github.moritz-poth.fona"
let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let pending = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Updates")

func fail(_ why: String) -> Never {
    // unified log only: the sandboxed app owns its container and could plant symlinks there (security scan F2)
    log.error("update refused: \(why, privacy: .public)")
    NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(5))
    exit(1)
}

func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.environment = [:]
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Reads a regular file (no symlinks) into memory once – verification and unpacking use these same bytes.
func readPlain(_ url: URL) -> Data? {
    guard let a = try? fm.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
          (a[.size] as? Int ?? 0) <= Limits.updateBytes else { return nil }
    return fm.contents(atPath: url.path)
}

guard appURL.pathExtension == "app", Bundle(url: appURL)?.bundleIdentifier == bundleID else { fail("not inside Fona.app") }
let installed = (Bundle(url: appURL)?.object(forInfoDictionaryKey: "FonaRelease") as? String).flatMap(AppVersion.init)

// wait until Fona has quit (it quits right after starting us – P0-a lesson)
for _ in 0..<100 where !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { usleep(100_000) }
guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { fail("Fona still running") }

guard let zip = readPlain(pending.appendingPathComponent("pending.zip")),
      let sig = readPlain(pending.appendingPathComponent("pending.zip.sig")) else { fail("no download") }
guard UpdateKey.verify(zip, signatureBase64: sig) else { fail("signature does not match the Fona update key") }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fona-update-\(UUID().uuidString)")
guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: false)) != nil else { fail("no temp folder") }
defer { try? fm.removeItem(at: tmp) }
let local = tmp.appendingPathComponent("update.zip")
guard (try? zip.write(to: local)) != nil, run("/usr/bin/ditto", ["-x", "-k", local.path, tmp.appendingPathComponent("x").path]) == 0 else {
    fail("could not unpack")
}
let items = (try? fm.contentsOfDirectory(atPath: tmp.appendingPathComponent("x").path)) ?? []
guard items == ["Fona.app"] else { fail("unexpected archive contents") }
let newApp = tmp.appendingPathComponent("x/Fona.app")
// no symlink inside the new app may point outside it
if let walker = fm.enumerator(at: newApp, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
    for case let u as URL in walker where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        let target = u.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(newApp.standardizedFileURL.path + "/") else { fail("symlink leaves the app") }
    }
}
let newBundle = Bundle(url: newApp)
guard newBundle?.bundleIdentifier == bundleID,
      let newVersion = (newBundle?.object(forInfoDictionaryKey: "FonaRelease") as? String).flatMap(AppVersion.init) else { fail("wrong app") }
if let installed { guard installed < newVersion else { fail("not newer than the installed version (no downgrades)") } }
guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else { fail("code signature broken") }

var trashed: NSURL?
do {
    try fm.trashItem(at: appURL, resultingItemURL: &trashed)
    try fm.moveItem(at: newApp, to: appURL)
} catch {
    if let t = trashed as URL?, !fm.fileExists(atPath: appURL.path) { try? fm.moveItem(at: t, to: appURL) }  // put the old one back
    fail("could not replace the app")
}
_ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
try? fm.removeItem(at: pending.appendingPathComponent("pending.zip"))
try? fm.removeItem(at: pending.appendingPathComponent("pending.zip.sig"))
log.notice("updated to \(newVersion.numbers.map(String.init).joined(separator: "."), privacy: .public)")
let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
_ = done.wait(timeout: .now() + 10)
exit(0)
