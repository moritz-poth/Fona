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
                UpdateBanner(updater: model.updater)  // sits on the footer line (user request 2026-11-13)
                FooterBar(settings: settings)
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
                Marquee(text: model.statusLine).foregroundStyle(Theme.text2).id(model.statusLine)
            }
            .contextMenu {
                if let s = model.current, model.library.station(s.id) != nil {
                    Button(L.t(.rename)) { model.renaming = s }
                }
            }
            Spacer(minLength: 0)
            PlayButton(model: model)
        }
        .padding(16)
        if model.newsSkipped {
            HStack(spacing: 8) {
                Image(systemName: "newspaper").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(L.t(.newsStillOn)).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Button(L.t(.toNews)) { model.rejoinNews() }.buttonStyle(FieldButtonStyle()).fixedSize()
            }
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.soft)
        }
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
                    HStack(spacing: 8) {
                        Text(verbatim: "Deutschlandfunk").font(.system(size: 14, weight: .semibold))
                        LevelBars(player: model.player).accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
                PlayButton(model: model)
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

/// Settings, manual, quit as icons in a bar at the bottom (user's pick 2026-11-13, canvas variant C without text).
struct FooterBar: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) var openWindow
    var body: some View {
        HStack(spacing: 4) {
            icon("gearshape", L.t(.settingsButton)) { open("settings") }.keyboardShortcut(",")
            icon("book", L.t(.manual)) { open("manual") }
            Spacer()
            Volume(settings: settings).padding(.trailing, 10)  // left of quit (user 2026-11-13)
            icon("power", L.t(.quit)) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(Theme.surface)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }

    func icon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.text2)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    /// Opens settings or the manual and closes the menu bar window (user 2026-11-12: it vanished only later, when the
    /// other window closed). The footer lives only in the menu bar window, so that is the key window here.
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
                Text(verbatim: model.newsActive || model.newsSkipped ? L.t(.newsNow) : L.f(.newsNext, model.nextNewsTime))
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
    var star = false  // "recently played": add-to-favourites star left of the bars (user 2026-11-14, replaces the time)
    @State private var hovering = false
    @State private var menuOpen = false
    var body: some View {
        let isCurrent = model.current?.url == station.url && model.isPlaying
        // during the news the bars sit on the station that is heard (user 2026-11-14)
        let newsRow = model.newsActive && model.isPlaying && NewsWatcher.isNewsStation(station.url)
        let bars = model.newsActive ? newsRow : isCurrent
        HStack(spacing: 10) {
            StationLogo(initials: station.initials, active: isCurrent)
            Text(verbatim: station.displayName).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if star {
                Button { model.toggleFavorite(station) } label: { Image(systemName: "star").foregroundStyle(Theme.text2) }
                    .buttonStyle(.plain).frame(width: 24, height: 24)
                    .accessibilityLabel("\(station.displayName) – \(L.t(.favoriteAdd))")
            }
            if bars {
                LevelBars(player: model.player).accessibilityHidden(true)
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovering || menuOpen ? 1 : 0)
            .accessibilityHidden(true)  // same entries as the accessibility actions below
        }
        .padding(.horizontal, 8).frame(height: 40)
        // news station at half intensity while it is heard; a light hover like the "…" (user 2026-11-14)
        .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? Theme.soft : newsRow ? Theme.soft.opacity(0.5) : hovering ? Theme.text2.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.switchOn, lineWidth: 1.5).opacity(menuOpen ? 1 : 0))
        .contentShape(Rectangle())
        // a tap gesture, not a Button: the Button kept the mouse and favourites could not be dragged (user 2026-11-14)
        .onTapGesture { model.play(station) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.play(station) }
        .onHover { hovering = $0 }
        // our own right-click outline (the system List drew a blue one): the row under the pointer when a menu opens
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in if hovering { menuOpen = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in menuOpen = false }
        .accessibilityLabel([station.displayName, isCurrent ? L.t(.playing) : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityActions {
            Button(model.library.isFavorite(station.id) ? L.t(.favoriteRemove) : L.t(.favoriteAdd)) { model.toggleFavorite(station) }
            Button(L.t(.rename)) { model.renaming = station }
            Button(L.t(.remove)) { model.remove(station) }
        }
        .contextMenu { menuItems }
    }

    @ViewBuilder var menuItems: some View {
        Button(model.library.isFavorite(station.id) ? L.t(.favoriteRemove) : L.t(.favoriteAdd)) { model.toggleFavorite(station) }
        Button(L.t(.rename)) { model.renaming = station }
        Button(L.t(.remove), role: .destructive) { model.remove(station) }
    }
}

struct FavoritesList: View {
    @ObservedObject var model: AppModel
    @State private var dragging: UUID?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.library.favoriteStations.isEmpty {
                    Text(L.t(.noFavorites)).foregroundStyle(Theme.text2).padding(.horizontal, 14).padding(.vertical, 8)
                }
                ForEach(model.library.favoriteStations) { s in
                    StationRow(model: model, station: s).padding(.horizontal, 6)
                        .opacity(dragging == s.id ? 0.4 : 1)
                        .onDrag { dragging = s.id; return NSItemProvider(object: s.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: FavoriteDrop(target: s.id, model: model, dragging: $dragging))
                }
                let recent = model.library.historyStations
                if !recent.isEmpty {
                    Text(L.t(.recentlyPlayed)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                        .padding(.top, 16).padding(.bottom, 4).padding(.horizontal, 14).accessibilityAddTraits(.isHeader)
                    ForEach(recent) { s in
                        StationRow(model: model, station: s, star: true).padding(.horizontal, 6)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// Reorders favourites while dragging over them (replaces List.onMove).
struct FavoriteDrop: DropDelegate {
    let target: UUID
    let model: AppModel
    @Binding var dragging: UUID?
    func dropEntered(info: DropInfo) {
        let ids = model.library.favoriteStations.map(\.id)
        guard let d = dragging, d != target, let from = ids.firstIndex(of: d), let to = ids.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.moveFavorites(IndexSet(integer: from), to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// One line that, when it does not fit, runs all the way out to the left, reappears at its start, pauses, runs again
/// (user 2026-11-14; before it bounced back and forth).
struct Marquee: View {
    let text: String
    @State private var boxWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let overflow = textWidth - boxWidth
        let moving = overflow > 1 && !reduceMotion
        Text(verbatim: text).lineLimit(1).truncationMode(.middle).opacity(moving ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(verbatim: text).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if moving {
                    Text(verbatim: text).fixedSize()
                        .offset(x: shift)
                        .task(id: textWidth) {
                            let run = Double(textWidth) / 30  // 30 pt/s
                            while !Task.isCancelled {
                                shift = 0
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.linear(duration: run)) { shift = -textWidth }
                                try? await Task.sleep(for: .seconds(run))
                            }
                        }
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
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
                else if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                    // no search: the whole directory for the chosen countries, A–Z, a page more as the end comes into view
                    if model.browse.shown.isEmpty && model.browseFailed { Text(L.t(.noDirectory)).foregroundStyle(Theme.text2).padding() }
                    else if model.browse.shown.isEmpty && !model.browse.finished { ProgressView().controlSize(.small).padding() }
                    else if model.browse.shown.isEmpty { Text(L.t(.noResults)).foregroundStyle(Theme.text2).padding() }
                    else {
                        Text(L.t(.sortedByName)).font(.system(size: 11)).foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                        List {
                            ForEach(model.browse.shown) { r in ResultRow(model: model, result: r).listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10)) }
                            if !model.browse.finished {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity).listRowSeparator(.hidden)
                                    .onAppear { model.browseMore() }
                            }
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                    }
                }
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
        .onAppear { model.browseMore() }
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
            VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                Text(verbatim: r.manual ? L.t(.installManual) : L.f(.updateAvailable, String(r.tag.dropFirst(r.tag.hasPrefix("v") ? 1 : 0))))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if updater.state != .downloading {
                    Button(L.t(.skipUpdate)) { updater.skip() }.buttonStyle(FieldButtonStyle())
                }
                if r.manual || AppUpdater.translocated {
                    Button("GitHub") { updater.openReleases() }.buttonStyle(FieldButtonStyle())
                } else if updater.state == .downloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L.t(.install)) { updater.install() }.buttonStyle(FieldButtonStyle(filled: true))
                }
            }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.soft))
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 12)  // same gap below as at the sides
        }
    }
}

/// Volume: a slim horizontal bar in the footer with a small speaker left of it (style of the user's pick 2026-11-12,
/// laid flat 2026-11-13). Drag or click on the bar; arrow keys when focused; VoiceOver adjustable.
struct Volume: View {
    @ObservedObject var settings: AppSettings
    static let length: CGFloat = 53  // 44 + 20 % (user 2026-11-13)
    @State var hovering = false
    @State var wheelMonitor: Any?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.text2).frame(width: 12)
                .onTapGesture { settings.volume = settings.volume == 0 ? 0.6 : 0 }  // quick mute
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.segBg).frame(width: Self.length, height: 4)
                Capsule().fill(Theme.switchOn).frame(width: max(4, Self.length * CGFloat(settings.volume)), height: 4)
            }
            .frame(width: Self.length, height: 16)  // taller hit area than the 4 pt bar
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                settings.volume = min(1, max(0, Double(g.location.x / Self.length)))
            })
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
/// window is open; stands still with "Reduce motion". Scaled to the loudest moment of the last ~3 s, because radio is
/// compressed so hard that a fixed scale sat at the top all the time (user 2026-11-13).
struct LevelBars: View {
    let player: Player
    @State var history: [Float] = Array(repeating: -60, count: 5)   // dBFS
    @State var recent: [Float] = Array(repeating: -60, count: 40)   // 40 × 80 ms

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        if reduceMotion {
            Image(systemName: "waveform")
        } else {
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().frame(width: 2, height: Self.height(history[i], top: recent.max() ?? -60))
                    }
                }
                .frame(width: 16, height: 14)
                .onChange(of: context.date) { _, _ in
                    let db = 20 * log10(max(player.currentLevel, 1e-6))
                    history.removeFirst(); history.append(db)
                    recent.removeFirst(); recent.append(db)
                }
            }
        }
    }

    /// The loudest recent moment → 14 pt, 12 dB below it (or silence) → 3 pt.
    static func height(_ db: Float, top: Float) -> CGFloat {
        let t = min(1, max(0, (db - (max(top, -48) - 12)) / 12))
        return 3 + 11 * CGFloat(t)
    }
}
