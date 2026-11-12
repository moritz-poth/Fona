// Fona – menu bar internet radio with automatic switch to the news (PLAN docs/PLAN.md).
import SwiftUI
import FonaCore

@main
struct FonaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model, settings: model.settings)
        } label: {
            Image(systemName: model.isPlaying ? "radio.fill" : "radio")
                .accessibilityLabel("Fona")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, settings: model.settings)
        }
    }
}
