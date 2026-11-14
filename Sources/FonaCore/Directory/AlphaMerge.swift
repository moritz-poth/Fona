import Foundation

/// The directory A–Z without a search (user 2026-11-14): one name-sorted feed per chosen country, merged page by page.
/// A station is shown only once every unfinished feed has a later name buffered, so later pages never insert above it.
public struct AlphaMerge: Sendable {
    public let keys: [String]                       // country codes; [""] = worldwide
    public private(set) var shown: [RadioBrowser.Result] = []
    var buffer: [String: [RadioBrowser.Result]] = [:]
    public private(set) var offset: [String: Int] = [:]
    var done: Set<String> = []

    public init(countries: [String]) {
        keys = countries.isEmpty ? [""] : Array(countries.prefix(RadioBrowser.maxCountries))
        for k in keys { buffer[k] = []; offset[k] = 0 }
    }

    /// Feeds that must deliver their next page before more can be shown.
    public var hungry: [String] { keys.filter { !done.contains($0) && buffer[$0]!.isEmpty } }
    public var finished: Bool { done.count == keys.count && buffer.values.allSatisfy(\.isEmpty) }

    public mutating func add(_ key: String, _ page: [RadioBrowser.Result], more: Bool) {
        guard buffer[key] != nil else { return }
        buffer[key]! += page
        offset[key, default: 0] += RadioBrowser.browsePage
        if !more { done.insert(key) }
        while hungry.isEmpty, let k = keys.filter({ !buffer[$0]!.isEmpty })
                .min(by: { Self.before(buffer[$0]![0], buffer[$1]![0]) }) {
            shown.append(buffer[k]!.removeFirst())
        }
    }

    static func before(_ a: RadioBrowser.Result, _ b: RadioBrowser.Result) -> Bool {
        a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
