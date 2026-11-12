import Foundation

/// A station the user keeps (favourite, history entry or own link). URLs are frozen when added and never updated
/// silently, not even from radio-browser (PLAN §3.1, H11).
public struct Station: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case radiobrowser, custom }
    public let id: UUID
    public let source: Source
    public let stationuuid: String?
    public let name: String
    public var customName: String?
    public let url: String
    public let countryCode: String?
    public let addedAt: Date

    public var displayName: String { customName ?? name }

    public init(id: UUID = UUID(), source: Source, stationuuid: String?, name: String, customName: String? = nil,
                url: String, countryCode: String?, addedAt: Date = Date()) {
        self.id = id; self.source = source; self.stationuuid = stationuuid; self.name = name
        self.customName = customName; self.url = url; self.countryCode = countryCode
        self.addedAt = Date(timeIntervalSince1970: addedAt.timeIntervalSince1970.rounded(.down))  // JSON keeps whole seconds
    }

    /// Initials for the logo placeholder (no logos from the net – security decision).
    public var initials: String {
        let words = displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
        return String(displayName.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    /// Checks a station read from disk like foreign data (A3).
    func isValid() -> Bool {
        guard name.count <= 120, (customName?.count ?? 0) <= 120, url.utf8.count <= Limits.maxURLLength,
              countryCode.map({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isUppercase } }) ?? true,
              (stationuuid?.count ?? 0) <= 64, case .success = URLPolicy.check(url, .stream) else { return false }
        return Sanitize.display(name) == name && customName.map { Sanitize.display($0) == $0 } ?? true
    }
}

public struct HistoryEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let playedAt: Date
}

/// library.json (PLAN §3.1): stations, ordered favourites, history (10, newest first, no duplicates).
public struct LibraryData: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public static let maxStations = 500, maxFavorites = 200, maxHistory = 10

    public var schemaVersion = currentSchema
    public var stations: [Station] = []
    public var favorites: [UUID] = []
    public var history: [HistoryEntry] = []

    public init() {}

    public func station(_ id: UUID) -> Station? { stations.first { $0.id == id } }
    public var favoriteStations: [Station] { favorites.compactMap(station) }
    public var historyStations: [Station] { history.compactMap { h in station(h.id) }.filter { !favorites.contains($0.id) } }
    public func isFavorite(_ id: UUID) -> Bool { favorites.contains(id) }

    /// Returns the stored station for a radio-browser entry or own link (re-uses an existing one with the same URL).
    public mutating func upsert(_ s: Station) -> UUID {
        if let existing = stations.first(where: { $0.url == s.url || ($0.stationuuid != nil && $0.stationuuid == s.stationuuid) }) {
            return existing.id
        }
        stations.append(s)
        return s.id
    }

    public mutating func addFavorite(_ id: UUID) {
        guard !favorites.contains(id), favorites.count < Self.maxFavorites else { return }
        favorites.append(id)
    }

    public mutating func removeFavorite(_ id: UUID) { favorites.removeAll { $0 == id }; prune() }

    public mutating func moveFavorites(from: IndexSet, to: Int) {
        var f = favorites
        let moving = from.sorted().map { f[$0] }
        for i in from.sorted(by: >) { f.remove(at: i) }
        let target = to - from.filter { $0 < to }.count
        f.insert(contentsOf: moving, at: max(0, min(target, f.count)))
        favorites = f
    }

    public mutating func played(_ id: UUID, at date: Date = Date()) {
        history.removeAll { $0.id == id }
        history.insert(HistoryEntry(id: id, playedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))), at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        prune()
    }

    public mutating func rename(_ id: UUID, to name: String?) {
        guard let i = stations.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.map(Sanitize.display).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        stations[i].customName = clean == stations[i].name ? nil : clean
    }

    /// Stations that are neither favourite nor in the history are dropped.
    mutating func prune() {
        let keep = Set(favorites).union(history.map(\.id))
        stations.removeAll { !keep.contains($0.id) }
    }

    /// A3: everything from disk is checked; any doubt → nil (the caller renames the file to .broken).
    public static func load(_ data: Data) -> LibraryData? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var lib = try? dec.decode(LibraryData.self, from: data), lib.schemaVersion == currentSchema,
              lib.stations.count <= maxStations, lib.favorites.count <= maxFavorites,
              lib.stations.allSatisfy({ $0.isValid() }), Set(lib.stations.map(\.id)).count == lib.stations.count else { return nil }
        let ids = Set(lib.stations.map(\.id))
        lib.favorites = lib.favorites.filter(ids.contains)
        lib.history = Array(lib.history.filter { ids.contains($0.id) }.prefix(maxHistory))
        return lib
    }

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// Reads and writes library.json atomically in the app's container.
public final class LibraryStore: @unchecked Sendable {
    public let file: URL
    public enum LoadResult: Equatable { case fresh, loaded, brokenReset }

    public init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("library.json")
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fona")
    }

    public func load() -> (LibraryData, LoadResult) {
        guard let data = FileManager.default.contents(atPath: file.path) else { return (LibraryData(), .fresh) }
        if let lib = LibraryData.load(data) { return (lib, .loaded) }
        let broken = file.deletingLastPathComponent().appendingPathComponent("library.broken.json")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.moveItem(at: file, to: broken)
        return (LibraryData(), .brokenReset)
    }

    public func save(_ lib: LibraryData) {
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".library-\(UUID().uuidString).json")
        do {
            try lib.encoded().write(to: tmp)
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: file)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}
