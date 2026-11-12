// Fona – menu bar internet radio with automatic switch to the news (PLAN docs/PLAN.md).
import SwiftUI
import FonaCore

@main
struct FonaApp: App {
    /// Template image from design/icon (disc with the F cut out); macOS tints it for light and dark menu bars.
    static let menuBarIcon: NSImage = {
        let img = Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "radio", accessibilityDescription: "Fona")!
        img.size = NSSize(width: 16, height: 16)
        img.isTemplate = true
        return img
    }()

    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, settings: model.settings)
        } label: {
            Image(nsImage: Self.menuBarIcon).accessibilityLabel("Fona")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, settings: model.settings)
        }

        Window(L.t(.manual), id: "manual") {
            ManualView(settings: model.settings)
        }
        .windowResizability(.contentMinSize)
    }
}
