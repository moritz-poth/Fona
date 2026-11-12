// Fona – menu bar internet radio with automatic switch to the news (PLAN docs/PLAN.md).
import SwiftUI
import FonaCore

@main
struct FonaApp: App {
    /// Template image from design/icon (disc with the F cut out); macOS tints it for light and dark menu bars.
    static let menuBarIcon: NSImage = {
        let img = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "radio", accessibilityDescription: "Fona")!
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, settings: model.settings)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // titled just "Fona" everywhere (user rule, like Mountpoint)
        Window("Fona", id: "settings") {
            SettingsView(model: model, settings: model.settings).modifier(TracksWindow(id: "settings"))
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Fona", id: "manual") {
            ManualView(settings: model.settings).modifier(TracksWindow(id: "manual"))
        }
        .windowResizability(.contentMinSize)
    }
}

/// The menu bar icon. Its view lives as long as the app, so it also hands the window opener to the menu and to
/// developer checks (`--show-settings`).
struct MenuBarLabel: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Image(nsImage: FonaApp.menuBarIcon).accessibilityLabel("Fona")
            .onAppear {
                MenuTarget.shared.openSettings = { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                if CommandLine.arguments.contains("--show-settings") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MenuTarget.shared.openSettings?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let titles = NSApp.mainMenu?.items.map(\.title) ?? []
                            let fona = NSApp.mainMenu?.items.first?.submenu?.items.map { "\($0.title)[\($0.keyEquivalent)]" } ?? []
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                MenuTarget.shared.closeWindows()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    log.notice("check after close: policy=\(NSApp.activationPolicy().rawValue) still running=true")
                                }
                            }
                            log.notice("check: policy=\(NSApp.activationPolicy().rawValue) windows=\(NSApp.windows.filter(\.isVisible).map(\.title), privacy: .public) menu=\(titles, privacy: .public) fona=\(fona, privacy: .public)")
                        }
                    }
                }
            }
    }
}
