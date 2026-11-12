import SwiftUI
import FonaCore

/// Settings window (design/canvas: Einstellungen) – one grouped page.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                section(L.t(.newsSection)) {
                    row(L.t(.newsSwitch)) { FonaSwitch(isOn: $settings.newsEnabled, label: L.t(.newsSwitch)) }
                    divider
                    row(L.t(.newsStation)) { Text(verbatim: "Deutschlandfunk").foregroundStyle(Theme.text2) }
                    divider
                    row(L.t(.scheduleLabel), hint: L.t(.scheduleHint)) {
                        dropdown(settings.newsSchedule == .hourly ? L.t(.hourly) : L.t(.hourlyAndHalf)) {
                            Button(L.t(.hourly)) { settings.newsSchedule = .hourly }
                            Button(L.t(.hourlyAndHalf)) { settings.newsSchedule = .hourlyAndHalf }
                        }
                    }
                    divider
                    row(L.t(.maxDuration)) {
                        dropdown(L.f(.minutes, settings.newsMaxMinutes)) {
                            ForEach(3...10, id: \.self) { m in Button(L.f(.minutes, m)) { settings.newsMaxMinutes = m } }
                        }
                    }
                }
                section(L.t(.stationsSection)) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(L.t(.showCountries))
                        Spacer()
                        FlowChips(settings: settings)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                section(L.t(.general)) {
                    row(L.t(.launchAtLogin)) { FonaSwitch(isOn: $settings.launchAtLogin, label: L.t(.launchAtLogin)) }
                    divider
                    row(L.t(.autoUpdate)) { FonaSwitch(isOn: $settings.autoUpdateCheck, label: L.t(.autoUpdate)) }
                    divider
                    row(L.t(.language)) {
                        dropdown(languageName(settings.language)) {
                            ForEach(AppSettings.Language.allCases, id: \.self) { l in Button(languageName(l)) { settings.language = l } }
                        }
                    }
                }
                section(L.t(.support)) {
                    row(L.t(.selfTest), hint: L.t(.selfTestHint)) {
                        Button(L.t(.runSelfTest)) { model.runSelfTest() }.buttonStyle(FieldButtonStyle())
                    }
                    divider
                    row(L.t(.report)) {
                        HStack { Button(L.t(.showLog)) { showLog() }.buttonStyle(FieldButtonStyle()) }
                    }
                    divider
                    row(L.t(.likeFona), hint: L.t(.likeFonaHint)) {
                        Button(L.t(.coffee)) { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/moritzpoth")!) }
                            .buttonStyle(FieldButtonStyle(filled: true))
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)  // the window fits its content
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .overlay(alignment: .top) { if let t = model.toast { ToastView(text: t).padding(.top, 8) } }
    }

    var divider: some View { Theme.border.opacity(0.5).frame(height: 1) }

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 10).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        }
    }

    func row(_ label: String, hint: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Theme.text2) }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Dropdown in text-field style (radius 6, light outline) – user request 2026-11-11.
    func dropdown(_ value: String, @ViewBuilder items: () -> some View) -> some View {
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(verbatim: value)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.field))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    func languageName(_ l: AppSettings.Language) -> String {
        switch l { case .system: return L.t(.languageSystem); case .de: return "Deutsch"; case .en: return "English" }
    }

    func showLog() {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Fona")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

struct FlowChips: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        HStack(spacing: 6) {
            ForEach(settings.countries, id: \.self) { c in
                Button { settings.countries.removeAll { $0 == c } } label: {
                    HStack(spacing: 4) { Text(verbatim: L.country(c)); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.soft))
                        .foregroundStyle(Theme.text)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(L.country(c)) – \(L.t(.remove))")
            }
            CountryMenu(settings: settings, compact: true) {}
                .accessibilityLabel(L.t(.addCountry))
        }
    }
}
