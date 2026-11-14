import SwiftUI
import FonaCore

/// Settings window (design/canvas: Einstellungen) – one grouped page.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) var openWindow

    init(model: AppModel, settings: AppSettings) {
        self.model = model; self.settings = settings; self.updater = model.updater
    }

    /// Always one line, so the settings never shift (user 2026-11-14): last check → animated search → result.
    var updateStatus: String {
        switch updater.state {
        case .checking: return L.t(.checkingUpdates)
        case .upToDate: return L.t(.upToDate)
        case .failed(let m): return m
        default:
            if let a = updater.available { return L.f(.updateAvailable, String(a.tag.dropFirst(a.tag.hasPrefix("v") ? 1 : 0))) }
            guard let d = updater.lastCheck else { return L.t(.notChecked) }
            let f = DateFormatter()
            f.locale = Locale(identifier: L.language.rawValue)
            f.doesRelativeDateFormatting = true; f.dateStyle = .medium; f.timeStyle = .short
            return L.f(.lastChecked, f.string(from: d))
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
                WindowTitle(text: L.t(.settings))
                section(L.t(.newsSection)) {
                    row(L.t(.newsSwitch)) { FonaSwitch(isOn: $settings.newsEnabled, label: L.t(.newsSwitch)) }
                    divider
                    row(L.t(.newsStation)) { Text(verbatim: "Deutschlandfunk").foregroundStyle(Theme.text2) }
                    divider
                    row(L.t(.scheduleLabel), hint: L.t(.scheduleHint)) {
                        dropdown(settings.newsSchedule == .hourly ? L.t(.hourly) : L.t(.hourlyAndHalf), label: L.t(.scheduleLabel)) {
                            Button(L.t(.hourly)) { settings.newsSchedule = .hourly }
                            Button(L.t(.hourlyAndHalf)) { settings.newsSchedule = .hourlyAndHalf }
                        }
                    }
                    divider
                    row(L.t(.maxDuration)) {
                        dropdown(L.f(.minutes, settings.newsMaxMinutes), label: L.t(.maxDuration)) {
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
                    row(L.t(.language)) {
                        dropdown(languageName(settings.language), label: L.t(.language)) {
                            ForEach(AppSettings.Language.allCases, id: \.self) { l in Button(languageName(l)) { settings.language = l } }
                        }
                    }
                }
                section(L.t(.updates)) {
                    row(L.f(.version, AppUpdater.current), hint: updateStatus, dots: updater.state == .checking) {
                        Button(L.t(.checkNow)) { model.updater.check(manual: true) }.buttonStyle(FieldButtonStyle())
                            .disabled(model.updater.state == .checking)
                    }
                    divider
                    row(L.t(.autoUpdate)) { FonaSwitch(isOn: $settings.autoUpdateCheck, label: L.t(.autoUpdate)) }
                    divider
                    row(L.t(.betas), hint: L.t(.betasHint)) { FonaSwitch(isOn: $settings.betas, label: L.t(.betas)) }
                }
                section(L.t(.support)) {
                    row(L.t(.selfTest), hint: L.t(.selfTestHint)) {
                        Button(L.t(.runSelfTest)) { model.runSelfTest() }.buttonStyle(FieldButtonStyle()).disabled(model.selfTestRunning)
                    }
                    divider
                    row(L.t(.report)) {
                        HStack {
                            Button(L.t(.reportButton)) { model.problemSheet = true }.buttonStyle(FieldButtonStyle())
                            Button(L.t(.showLog)) { showLog() }.buttonStyle(FieldButtonStyle())
                        }
                    }
                    divider
                    row(L.t(.manual)) {
                        Button(L.t(.showManual)) { NSApp.activate(ignoringOtherApps: true); openWindow(id: "manual") }.buttonStyle(FieldButtonStyle())
                    }
                    divider
                    row(L.t(.likeFona), hint: L.t(.likeFonaHint)) {
                        Button(L.t(.coffee)) { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/moritzpoth")!) }
                            .buttonStyle(FieldButtonStyle(filled: true))
                    }
                }
                section(L.t(.about)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: "Fona \(AppUpdater.current) · \(L.t(.aboutCopyright))").fontWeight(.semibold)
                        Text(L.t(.aboutLicense)).font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Text(L.t(.aboutWarranty)).font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(L.t(.license)) {
                                if let u = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") { NSWorkspace.shared.open(u) }
                            }.buttonStyle(FieldButtonStyle())
                            Button(L.t(.sourceCode)) { NSWorkspace.shared.open(URL(string: "https://github.com/moritz-poth/Fona")!) }
                                .buttonStyle(FieldButtonStyle())
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id("about")
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fonaShowAbout)) { _ in
            withAnimation { proxy.scrollTo("about", anchor: .top) }
        }
        .onAppear {
            if AppWindows.aboutRequested {
                AppWindows.aboutRequested = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo("about", anchor: .top) }
            }
        }
        }
        .frame(width: 560, height: 720)  // long page: scrolls; fits a 13" screen
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .overlay(alignment: .top) { if let t = model.toast { ToastView(text: t).padding(.top, 8) } }
        .sheet(isPresented: $model.problemSheet) { ProblemSheet(model: model) }
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

    func row(_ label: String, hint: String? = nil, dots: Bool = false, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let hint {
                    HStack(spacing: 0) {
                        Text(hint).lineLimit(1)
                        if dots { WaitingDots() }
                    }
                    .font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Dropdown in text-field style (radius 6, light outline) – user request 2026-11-11.
    func dropdown(_ value: String, label: String = "", @ViewBuilder items: () -> some View) -> some View {
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
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    func languageName(_ l: AppSettings.Language) -> String {
        switch l { case .system: return L.t(.languageSystem); case .de: return "Deutsch"; case .en: return "English" }
    }

    func showLog() {
        FileLog.shared.write("show log")
        NSWorkspace.shared.activateFileViewerSelecting([FileLog.shared.file])
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

struct ProblemSheet: View {
    @ObservedObject var model: AppModel
    @State var text = ""
    @State var contact = ""
    @State var attach = true
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t(.reportTitle)).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(L.t(.reportDescription)).font(.system(size: 12, weight: .semibold))
            TextEditor(text: $text).font(.system(size: 13)).frame(height: 120).accessibilityLabel(L.t(.reportDescription))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.field))
            Text(L.t(.reportContact)).font(.system(size: 12, weight: .semibold))
            TextField("", text: $contact).textFieldStyle(.roundedBorder).accessibilityLabel(L.t(.reportContact))
            Toggle(L.t(.reportAttach), isOn: $attach).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(L.t(.cancel)) { dismiss() }.buttonStyle(FieldButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L.t(.send)) { model.sendProblem(text: text, contact: contact, attach: attach); dismiss() }
                    .buttonStyle(FieldButtonStyle(filled: true)).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Theme.bg)
    }
}

/// Three dots lighting up one after another while something is being fetched (width stays the same).
struct WaitingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
            let step = reduceMotion ? 3 : Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 4
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in Text(verbatim: ".").opacity(i < step ? 1 : 0.2) }
            }
        }
        .accessibilityHidden(true)
    }
}
