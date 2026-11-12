import Foundation

/// radio-browser.info client (PLAN §3.3). Everything it returns is foreign data: names are sanitized, URLs must pass
/// URLPolicy, unsupported codecs are hidden. `homepage` and `favicon` are never read.
public final class RadioBrowser: @unchecked Sendable {
    public struct Result: Equatable, Identifiable, Sendable {
        public var id: String { stationuuid }
        public let stationuuid: String
        public let name: String
        public let url: String
        public let countryCode: String?
        public let tags: String
        public let bitrate: Int
        public let codec: String
        public let clickcount: Int

        public init(stationuuid: String, name: String, url: String, countryCode: String?, tags: String, bitrate: Int, codec: String, clickcount: Int) {
            self.stationuuid = stationuuid; self.name = name; self.url = url; self.countryCode = countryCode
            self.tags = tags; self.bitrate = bitrate; self.codec = codec; self.clickcount = clickcount
        }

        public func station() -> Station {
            Station(source: .radiobrowser, stationuuid: stationuuid, name: name, url: url, countryCode: countryCode)
        }
    }

    public struct Country: Equatable, Sendable { public let code: String; public let stations: Int }

    struct RawStation: Decodable {
        let stationuuid: String?
        let name: String?
        let url: String?
        let url_resolved: String?
        let countrycode: String?
        let tags: String?
        let bitrate: Int?
        let codec: String?
        let clickcount: Int?
    }

    struct RawCountry: Decodable { let iso_3166_1: String?; let stationcount: Int? }

    public static let fallbackServers = ["de1.api.radio-browser.info", "de2.api.radio-browser.info", "fi1.api.radio-browser.info"]
    public static let maxResults = 100
    public static let maxCountries = 20

    let gate: NetGate
    var servers: [String] = []
    let lock = NSLock()

    public init(gate: NetGate = .shared) { self.gate = gate }

    /// Server list from `all.api.radio-browser.info/json/servers`, shuffled, with a fixed fallback.
    func serverList() async -> [String] {
        lock.lock(); let cached = servers; lock.unlock()
        if !cached.isEmpty { return cached }
        var list: [String] = []
        if let (_, data) = try? await gate.fetch("https://all.api.radio-browser.info/json/servers", .directory),
           let raw = try? JSONDecoder().decode([[String: String]].self, from: data) {
            list = raw.compactMap { $0["name"]?.lowercased() }.filter(Limits.isRadioBrowserHost)
        }
        list = Array(Set(list)).shuffled()
        if list.isEmpty { list = Self.fallbackServers.shuffled() }
        lock.lock(); servers = list; lock.unlock()
        return list
    }

    func get(_ path: String) async throws -> Data {
        var last: Error = Rejection.network
        for host in await serverList().prefix(3) {
            do { return try await gate.fetch("https://\(host)\(path)", .directory).1 } catch { last = error }
        }
        throw last
    }

    static func q(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    /// Search by name; one request per country (the API takes one country code), merged by click count.
    public func search(_ text: String, countries: [String]) async throws -> [Result] {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard query.count >= 2 else { return [] }
        let codes = countries.filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isUppercase } }.prefix(Self.maxCountries)
        let base = "/json/stations/search?name=\(Self.q(query))&hidebroken=true&order=clickcount&reverse=true&limit=\(Self.maxResults)"
        let paths = codes.isEmpty ? [base] : codes.map { base + "&countrycode=\($0)" }
        var all: [Result] = []
        try await withThrowingTaskGroup(of: [Result].self) { group in
            for p in paths { group.addTask { Self.parseStations(try await self.get(p)) } }
            for try await part in group { all += part }
        }
        var seen = Set<String>()
        return all.sorted { $0.clickcount > $1.clickcount }.filter { seen.insert($0.url).inserted }.prefix(Self.maxResults).map { $0 }
    }

    public func countries() async throws -> [Country] {
        Self.parseCountries(try await get("/json/countries"))
    }

    /// S6: every entry checked; invalid ones disappear.
    public static func parseStations(_ data: Data) -> [Result] {
        guard let raw = try? JSONDecoder().decode([RawStation].self, from: data) else { return [] }
        return raw.prefix(1000).compactMap { r in
            guard let uuid = r.stationuuid, uuid.count <= 64, uuid.allSatisfy({ $0.isHexDigit || $0 == "-" }),
                  let rawName = r.name else { return nil }
            let name = String(Sanitize.display(rawName).prefix(120))
            let url = [r.url_resolved, r.url].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            guard !name.isEmpty, case .success = URLPolicy.check(url, .stream) else { return nil }
            let codec = Sanitize.display(r.codec ?? "").uppercased()
            guard !["OGG", "OPUS", "FLAC", "VORBIS"].contains(where: codec.contains) else { return nil }
            let cc = r.countrycode.flatMap { $0.count == 2 && $0.allSatisfy({ $0.isASCII && $0.isLetter }) ? $0.uppercased() : nil }
            return Result(stationuuid: uuid, name: name, url: url, countryCode: cc,
                          tags: String(Sanitize.display(r.tags ?? "").prefix(80)),
                          bitrate: min(max(r.bitrate ?? 0, 0), 9999), codec: String(codec.prefix(12)),
                          clickcount: max(r.clickcount ?? 0, 0))
        }
    }

    public static func parseCountries(_ data: Data) -> [Country] {
        guard let raw = try? JSONDecoder().decode([RawCountry].self, from: data) else { return [] }
        var best: [String: Int] = [:]
        for c in raw {
            guard let code = c.iso_3166_1?.uppercased(), code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            best[code] = max(best[code] ?? 0, c.stationcount ?? 0)
        }
        return best.map { Country(code: $0.key, stations: $0.value) }.sorted { $0.code < $1.code }
    }
}
