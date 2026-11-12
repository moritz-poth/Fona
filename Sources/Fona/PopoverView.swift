import SwiftUI
import FonaCore

/// The menu bar window (design/canvas: Main, Nachrichten, AlleSender, Link).
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if model.newsActive { NewsHeader(model: model) } else { Header(model: model) }
                NewsRow(model: model, settings: settings)
                SegmentPicker(tab: $model.tab)
                if let n = model.notice { NoticeCard(text: n) { model.notice = nil } }
                if model.tab == .favorites { FavoritesList(model: model) } else { AllStations(model: model, settings: settings) }
                UpdateBanner(updater: model.updater)  // at the lower edge (user request 2026-11-12)
            }
            if model.addSheet { AddStationSheet(model: model).transition(.move(edge: .top)) }
            if let r = model.renaming { RenameSheet(model: model, station: r) }
            if let t = model.toast { ToastView(text: t).padding(.top, 8) }
        }
        .frame(width: 360, height: 600)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
    }
}

struct Header: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
            StationLogo(initials: model.current?.initials ?? "F", size: 48, active: model.isPlaying)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.current?.displayName ?? "Fona").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(verbatim: model.statusLine).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
            }
            .contextMenu {
                if let s = model.current, model.library.station(s.id) != nil {
                    Button(L.t(.rename)) { model.renaming = s }
                }
            }
            Spacer(minLength: 0)
            VerticalVolume(settings: model.settings)
            PlayButton(model: model)
            GearMenu()
        }
        .padding(16)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
}

struct NewsHeader: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StationLogo(initials: "DLF", size: 48, active: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L.language == .de ? "NACHRICHTEN" : "NEWS").font(.system(size: 10, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Theme.bg).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.text))
                    Text(verbatim: "Deutschlandfunk").font(.system(size: 14, weight: .semibold))
                }
                Spacer(minLength: 0)
                PlayButton(model: model)
                GearMenu()
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(verbatim: L.f(.newsBackTo, model.current?.displayName ?? "")).lineLimit(1)
                Spacer()
                Button(L.t(.backNow)) { model.backFromNews() }.buttonStyle(FieldButtonStyle())
            }
            .foregroundStyle(Theme.text2)
        }
        .foregroundStyle(Theme.text)
        .padding(16)
        .background(Theme.soft)
    }
}

struct PlayButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                .frame(width: 40, height: 40).background(Circle().fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(model.current == nil)
        .accessibilityLabel(model.isPlaying ? L.t(.pause) : L.t(.play))
        .help(model.isPlaying ? L.t(.pause) : L.t(.play))
    }
}

struct GearMenu: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Menu {
            Button(L.t(.settings) + " …") { open("settings") }
                .keyboardShortcut(",")
            Button(L.t(.manual)) { open("manual") }
            Divider()
            Button(L.t(.quit)) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Theme.text2)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L.t(.settingsButton))
        .help(L.t(.settingsButton))
    }

    /// Opens settings or the manual and closes the menu bar window (user 2026-11-12: it vanished only later, when the
    /// other window closed). The gear lives only in the menu bar window, so that is the key window here.
    func open(_ id: String) {
        let menuBarWindow = NSApp.keyWindow
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        menuBarWindow?.close()
    }
}

struct NewsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "newspaper").font(.system(size: 16)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t(.newsSwitch)).fontWeight(.semibold)
                Text(verbatim: model.newsActive ? L.t(.newsNow) : L.f(.newsNext, model.nextNewsTime))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
            Spacer()
            FonaSwitch(isOn: $settings.newsEnabled, label: L.t(.newsSwitch))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .padding([.horizontal, .top], 12)
    }
}

struct SegmentPicker: View {
    @Binding var tab: AppModel.Tab
    var body: some View {
        HStack(spacing: 0) {
            seg(.favorites, L.t(.favorites))
            seg(.all, L.t(.allStations))
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.segBg))
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
    }
    func seg(_ t: AppModel.Tab, _ title: String) -> some View {
        Button { tab = t } label: {
            Text(title).fontWeight(tab == t ? .semibold : .regular).frame(maxWidth: .infinity).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(tab == t ? Theme.segOn : .clear)
                    .shadow(color: .black.opacity(tab == t ? 0.12 : 0), radius: 1, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == t ? .isSelected : [])
    }
}

struct StationRow: View {
    @ObservedObject var model: AppModel
    let station: Station
    var trailing: String?
    var body: some View {
        let isCurrent = model.current?.url == station.url && model.isPlaying
        Button { model.play(station) } label: {
            HStack(spacing: 10) {
                StationLogo(initials: station.initials, active: isCurrent)
                Text(verbatim: station.displayName).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if isCurrent {
                    LevelBars(player: model.player).accessibilityHidden(true)
                } else if let trailing {
                    Text(verbatim: trailing).font(.system(size: 11)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? Theme.soft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([station.displayName, isCurrent ? L.t(.playing) : nil, trailing].compactMap { $0 }.joined(separator: ", "))
        .accessibilityActions {
            Button(model.library.isFavorite(station.id) ? L.t(.favoriteRemove) : L.t(.favoriteAdd)) { model.toggleFavorite(station) }
            Button(L.t(.rename)) { model.renaming = station }
            Button(L.t(.remove)) { model.remove(station) }
        }
        .contextMenu {
            Button(model.library.isFavorite(station.id) ? L.t(.favoriteRemove) : L.t(.favoriteAdd)) { model.toggleFavorite(station) }
            Button(L.t(.rename)) { model.renaming = station }
            Button(L.t(.remove), role: .destructive) { model.remove(station) }
        }
    }
}

struct FavoritesList: View {
    @ObservedObject var model: AppModel
    var body: some View {
        List {
            if model.library.favoriteStations.isEmpty {
                Text(L.t(.noFavorites)).foregroundStyle(Theme.text2).listRowSeparator(.hidden)
            }
            ForEach(model.library.favoriteStations) { s in
                StationRow(model: model, station: s).listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)).listRowSeparator(.hidden)
            }
            .onMove { model.moveFavorites($0, $1) }
            let recent = model.library.historyStations
            if !recent.isEmpty {
                Text(L.t(.recentlyPlayed)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                    .padding(.top, 8).listRowSeparator(.hidden).accessibilityAddTraits(.isHeader)
                ForEach(recent) { s in
                    HStack(spacing: 0) {
                        StationRow(model: model, station: s, trailing: relative(s))
                        Button { model.toggleFavorite(s) } label: { Image(systemName: "star").foregroundStyle(Theme.text2) }
                            .buttonStyle(.plain).frame(width: 24, height: 24)
                            .accessibilityLabel("\(s.displayName) – \(L.t(.favoriteAdd))")
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10)).listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    func relative(_ s: Station) -> String {
        guard let d = model.library.history.first(where: { $0.id == s.id })?.playedAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L.language.rawValue)
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        let now = Date()
        return now.timeIntervalSince(d) < 60 ? f.localizedString(fromTimeInterval: 0) : f.localizedString(for: min(d, now), relativeTo: now)
    }
}

struct AllStations: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text2).accessibilityHidden(true)
                    TextField(L.t(.searchPlaceholder), text: $model.query).textFieldStyle(.plain)
                        .accessibilityLabel(L.t(.searchPlaceholder))
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L.t(.clearSearch)).help(L.t(.clearSearch))
                    }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.field))
                CountryMenu(settings: settings) { model.scheduleSearch() }
                Button { model.addSheet = true } label: { Image(systemName: "plus").frame(width: 14, height: 14) }
                    .buttonStyle(FieldButtonStyle()).accessibilityLabel(L.t(.addStation)).help(L.t(.addStation))
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            Group {
                if model.searching { ProgressView().controlSize(.small).padding() }
                else if let e = model.searchError { Text(verbatim: e).foregroundStyle(Theme.text2).padding() }
                else if model.query.trimmingCharacters(in: .whitespaces).count < 2 { Text(L.t(.searchHint)).foregroundStyle(Theme.text2).padding() }
                else if model.results.isEmpty { Text(L.t(.noResults)).foregroundStyle(Theme.text2).padding() }
                else {
                    Text(verbatim: L.f(.stationCount, model.results.count) + " · " + L.t(.sortedByPopularity))
                        .font(.system(size: 11)).foregroundStyle(Theme.text2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    List(model.results) { r in ResultRow(model: model, result: r).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10)) }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ResultRow: View {
    @ObservedObject var model: AppModel
    let result: RadioBrowser.Result
    var body: some View {
        let fav = model.isFavorite(url: result.url)
        let s = result.station()
        HStack(spacing: 4) {
            Button { model.play(s) } label: {
                HStack(spacing: 10) {
                    StationLogo(initials: s.initials, active: model.current?.url == result.url && model.isPlaying)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: result.name).lineLimit(1)
                        Text(verbatim: meta).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .frame(height: 40).padding(.leading, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(result.name), \(meta)")
            Button { model.toggleFavorite(s) } label: {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Theme.switchOn : Theme.text2)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fav ? L.t(.favoriteRemove) : L.t(.favoriteAdd))
            .accessibilityValue(result.name)
            .padding(.trailing, 4)
        }
    }
    var meta: String {
        var parts: [String] = []
        if let c = result.countryCode { parts.append(L.country(c)) }
        if let tag = result.tags.split(separator: ",").first { parts.append(String(tag)) }
        if result.bitrate > 0 { parts.append("\(result.bitrate) kbit/s") }
        return parts.joined(separator: " · ")
    }
}

struct CountryMenu: View {
    @ObservedObject var settings: AppSettings
    var compact = false
    var changed: () -> Void
    static let common = ["DE", "AT", "CH", "FR", "IT", "NL", "BE", "LU", "DK", "PL", "CZ", "ES", "GB", "US"]
    var body: some View {
        Menu {
            Button(L.t(.worldwide)) { settings.countries = []; changed() }
            Divider()
            ForEach(Self.common, id: \.self) { c in
                Button { toggle(c) } label: {
                    if settings.countries.contains(c) { Label(L.country(c), systemImage: "checkmark") } else { Text(L.country(c)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if compact {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                } else {
                    Text(verbatim: settings.countries.isEmpty ? L.t(.worldwide) : settings.countries.prefix(3).joined(separator: ", "))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, compact ? 6 : 8).frame(height: compact ? 24 : 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.field))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L.t(.countries))
    }
    func toggle(_ c: String) {
        if let i = settings.countries.firstIndex(of: c) { settings.countries.remove(at: i) } else if settings.countries.count < 20 { settings.countries.append(c) }
        changed()
    }
}

struct AddStationSheet: View {
    @ObservedObject var model: AppModel
    @FocusState var focused: Bool
    @State var url = ""
    @State var name = ""
    @State var favorite = true
    @State var result: AppModel.ProbeResult?
    @State var checking = false
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { model.addSheet = false }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                Text(L.t(.addTitle)).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t(.streamLink)).font(.system(size: 12, weight: .semibold))
                    TextField("https://", text: $url).textFieldStyle(.roundedBorder)
                        .focused($focused).accessibilityLabel(L.t(.streamLink))
                        .onSubmit(check).onChange(of: url) { _, _ in result = nil }
                    if checking { Text(L.t(.checking)).font(.system(size: 12)).foregroundStyle(Theme.text2) }
                    switch result {
                    case .ok(let d)?: Label { Text(verbatim: L.f(.linkOK, d)) } icon: { Image(systemName: "checkmark") }
                        .font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.rgb(0x2F6B5E)))
                    case .refused(let m)?: Label { Text(verbatim: m) } icon: { Image(systemName: "xmark.octagon") }
                        .font(.system(size: 12)).foregroundStyle(.red)
                    case nil: EmptyView()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t(.name)).font(.system(size: 12, weight: .semibold))
                    TextField("", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel(L.t(.name))
                }
                Toggle(L.t(.addToFavorites), isOn: $favorite).toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button(L.t(.cancel)) { model.addSheet = false }.buttonStyle(FieldButtonStyle()).keyboardShortcut(.cancelAction)
                    if case .ok? = result {
                        Button(L.t(.add)) { model.addCustom(url: url, name: name, favorite: favorite); model.addSheet = false }
                            .buttonStyle(FieldButtonStyle(filled: true)).keyboardShortcut(.defaultAction)
                    } else {
                        Button(L.t(.add)) { check() }.buttonStyle(FieldButtonStyle(filled: true)).keyboardShortcut(.defaultAction)
                            .disabled(url.isEmpty || checking)
                    }
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(color: .black.opacity(0.18), radius: 12, y: 8))
            .padding(.horizontal, 12).padding(.top, 76)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .onAppear { focused = true }
        }
    }
    func check() {
        let u = url.trimmingCharacters(in: .whitespaces)
        checking = true; result = nil
        Task {
            let r = await model.probe(u)
            checking = false; result = r
            if case .ok = r, name.isEmpty, case .success(let c) = URLPolicy.check(u, .stream) { name = c.host }
        }
    }
}

struct RenameSheet: View {
    @ObservedObject var model: AppModel
    let station: Station
    @State var name = ""
    @FocusState var focused: Bool
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { model.renaming = nil }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t(.rename)).font(.system(size: 15, weight: .semibold))
                TextField(station.name, text: $name).textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel(L.t(.name)).onAppear { name = station.displayName; focused = true }
                HStack {
                    Spacer()
                    Button(L.t(.cancel)) { model.renaming = nil }.buttonStyle(FieldButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(L.t(.done)) { model.rename(station, name); model.renaming = nil }
                        .buttonStyle(FieldButtonStyle(filled: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(color: .black.opacity(0.18), radius: 12, y: 8))
            .padding(.horizontal, 12).padding(.top, 120)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}

struct NoticeCard: View {
    let text: String
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(verbatim: text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L.t(.done))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Theme.accent).shadow(color: .black.opacity(0.15), radius: 6, y: 3))
            .accessibilityAddTraits(.isStaticText)
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        if let r = updater.available {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                Text(verbatim: r.manual ? L.t(.installManual) : L.f(.updateAvailable, String(r.tag.dropFirst(r.tag.hasPrefix("v") ? 1 : 0))))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if r.manual || AppUpdater.translocated {
                    Button("GitHub") { updater.openReleases() }.buttonStyle(FieldButtonStyle())
                } else if updater.state == .downloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L.t(.install)) { updater.install() }.buttonStyle(FieldButtonStyle(filled: true))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.soft))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)  // same gap below as at the sides
        }
    }
}

/// Volume: a slim vertical bar left of the play button with a small speaker below (user's pick 2026-11-12,
/// style of proposal 9). Drag or click on the bar; arrow keys when focused; VoiceOver adjustable.
struct VerticalVolume: View {
    @ObservedObject var settings: AppSettings
    static let height: CGFloat = 30
    @State var hovering = false
    @State var wheelMonitor: Any?
    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Theme.segBg).frame(width: 4, height: Self.height)
                Capsule().fill(Theme.switchOn).frame(width: 4, height: max(4, Self.height * CGFloat(settings.volume)))
            }
            .frame(width: 16, height: Self.height)  // wider hit area than the 4 pt bar
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                settings.volume = min(1, max(0, Double(1 - g.location.y / Self.height)))
            })
            Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.text2)
                .onTapGesture { settings.volume = settings.volume == 0 ? 0.6 : 0 }  // quick mute
        }
        .focusable(true, interactions: .edit)
        .focusEffectDisabled()  // no ring or outline at all (user 2026-11-12); arrow keys still work
        .onHover { hovering = $0 }
        .onAppear {
            // mouse wheel / trackpad over the control changes the volume (SwiftUI has no wheel modifier on macOS 14)
            guard wheelMonitor == nil else { return }
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                guard hovering else { return e }
                let dy = e.isDirectionInvertedFromDevice ? -e.scrollingDeltaY : e.scrollingDeltaY  // wheel up = louder
                settings.volume = Self.wheel(settings.volume, dy, precise: e.hasPreciseScrollingDeltas)
                return nil
            }
        }
        .onDisappear { if let m = wheelMonitor { NSEvent.removeMonitor(m) }; wheelMonitor = nil }
        .onMoveCommand { d in
            if d == .up || d == .right { settings.volume = min(1, settings.volume + 0.1) }
            if d == .down || d == .left { settings.volume = max(0, settings.volume - 0.1) }
        }
        .help(L.t(.volume))
        .accessibilityElement()
        .accessibilityLabel(L.t(.volume))
        .accessibilityValue("\(Int((settings.volume * 100).rounded())) %")
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: settings.volume = min(1, settings.volume + 0.1)
            case .decrement: settings.volume = max(0, settings.volume - 0.1)
            @unknown default: break
            }
        }
    }

    /// One wheel notch = 5 %; trackpads report pixels, 100 px = full range.
    static func wheel(_ volume: Double, _ dy: CGFloat, precise: Bool) -> Double {
        min(1, max(0, volume + Double(dy) * (precise ? 0.01 : 0.05)))
    }
}

/// Five bars showing the real loudness of the last moments (user's pick 2026-11-12, proposal 4). Updates only while the
/// window is open; stands still with "Reduce motion".
struct LevelBars: View {
    let player: Player
    @State var history: [Float] = Array(repeating: 0, count: 5)
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform")
        } else {
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().frame(width: 2, height: Self.height(history[i]))
                    }
                }
                .frame(width: 16, height: 14)
                .onChange(of: context.date) { _, _ in
                    history.removeFirst()
                    history.append(player.currentLevel)
                }
            }
        }
    }

    /// −36 dBFS → 3 pt, −8 dBFS and louder → 14 pt (radio RMS mostly sits between −27 and −12 dB).
    static func height(_ rms: Float) -> CGFloat {
        let db = 20 * log10(max(rms, 1e-6))
        let t = min(1, max(0, (db + 36) / 28))
        return 3 + 11 * CGFloat(t)
    }
}
