import AppKit
import FonaCore

/// Update check and download (PLAN §7). Fona only fetches and pre-checks; FonaUpdater (no sandbox) verifies again and
/// swaps the app. Releases: GitHub tag `v<version>`, assets `Fona-<version>.zip` + `.zip.sig` (Ed25519, "Fona update key").
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, downloading, failed(String) }

    @Published var available: Release?
    @Published var state = State.idle
    let settings: AppSettings
    var timer: Timer?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "FonaRelease") as? String ?? "dev" }
    /// Started from the Downloads folder or the DMG, macOS runs the app from a hidden temporary copy
    /// (App Translocation) – it cannot replace itself there.
    static var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") || Bundle.main.bundlePath.hasPrefix("/Volumes/") }

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard Self.current != "dev" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfAllowed() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfAllowed() }
        }
    }

    func checkIfAllowed() { if settings.autoUpdateCheck { check(manual: false) } }

    func check(manual: Bool) {
        guard state != .checking, state != .downloading else { return }
        if manual { state = .checking }
        let betas = settings.betas || AppVersion(Self.current)?.beta != nil
        Task {
            let release: Release?
            if let (_, data) = try? await NetGate.shared.fetch(Release.api, .update) {
                release = UpdateCheck.newestRelease(fromJSON: data, includePrereleases: betas)
            } else {
                release = nil
                if manual { state = .failed(L.t(.updateCheckFailed)); return }
            }
            if let release, let new = AppVersion(release.tag), let mine = AppVersion(Self.current), mine < new {
                if available?.tag != release.tag { FileLog.shared.write("update available: \(release.tag)") }
                available = release
                if manual { state = .idle }
            } else {
                available = nil
                if manual { state = .upToDate }
            }
        }
    }

    /// Download → verify signature → hand over to FonaUpdater → quit right away (it waits until we are gone).
    func install() {
        guard let r = available, !r.manual, let sigURL = r.signature, state != .downloading, !Self.translocated else { return }
        state = .downloading
        FileLog.shared.write("downloading update \(r.tag)")
        Task {
            do {
                let sig = try await NetGate.shared.fetch(sigURL, .update).1
                let zip = try await NetGate.shared.fetch(r.zip, .update).1
                guard UpdateKey.verify(zip, signatureBase64: sig) else { throw Rejection.notAudio }
                let dir = UpdateCheck.pendingDirectory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try zip.write(to: dir.appendingPathComponent("pending.zip"), options: .atomic)
                try sig.write(to: dir.appendingPathComponent("pending.zip.sig"), options: .atomic)
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FonaUpdater.app")
                FileLog.shared.write("handing update \(r.tag) to the updater")
                NSWorkspace.shared.openApplication(at: helper, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { FileLog.shared.write("updater could not start: \(error.localizedDescription)") }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            } catch {
                FileLog.shared.write("update download failed: \((error as? Rejection)?.code ?? "error")")
                state = .failed(L.t(.updateFailed))
            }
        }
    }

    func openReleases() { NSWorkspace.shared.open(URL(string: Release.releasesPage)!) }
}
