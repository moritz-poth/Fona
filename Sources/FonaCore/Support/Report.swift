import Foundation

/// Report for the shared report worker (Mountpoint `worker/`): JSON → file + issue in the private repo
/// `moritz-poth/fona-reports`. Anonymous (A5): no URLs, station names, titles, user or computer names.
public struct Report: Codable, Equatable, Sendable {
    public struct Result: Codable, Equatable, Sendable {
        public let id: String, title: String, status: String, detail: String, seconds: Double
        public init(id: String, title: String, status: String, detail: String, seconds: Double) {
            self.id = id; self.title = title; self.status = status; self.detail = detail; self.seconds = seconds
        }
    }
    public var kind: String            // "selftest" | "problem"
    public var product = "fona"
    public var app: String
    public var build: String
    public var date: String
    public var system: [String: String]
    public var results: [Result]
    public var durationSeconds: Double
    public var log: [String]
    public var note: String?
    public var contact: String?

    public init(kind: String, app: String, build: String, date: String, system: [String: String], results: [Result],
                durationSeconds: Double, log: [String], note: String?, contact: String?) {
        self.kind = kind; self.app = app; self.build = build; self.date = date; self.system = system; self.results = results
        self.durationSeconds = durationSeconds; self.log = log; self.note = note; self.contact = contact
    }

    /// Catalogue results grouped per area (the worker takes ≤ 100 results; the catalogue has more checks).
    public static func results(from checks: [CheckResult], seconds: Double) -> [Result] {
        let areas = Dictionary(grouping: checks, by: \.area).sorted { $0.key < $1.key }
        return areas.map { area, items in
            let failed = items.filter { !$0.passed }
            let detail = failed.isEmpty ? "\(items.count)/\(items.count) passed"
                : "\(items.count - failed.count)/\(items.count) passed; failed: " + failed.map { "\($0.id) (\($0.failure ?? ""))" }.joined(separator: ", ")
            return Result(id: area, title: area, status: failed.isEmpty ? "pass" : "fail", detail: String(detail.prefix(1000)),
                          seconds: (seconds / Double(max(areas.count, 1)) * 100).rounded() / 100)
        }
    }

    /// Only what helps to reproduce a problem: OS, architecture, model family, languages.
    public static func systemInfo(language: String) -> [String: String] {
        var model = [CChar](repeating: 0, count: 64), size = 64
        sysctlbyname("hw.model", &model, &size, nil, 0)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": arch,
            "model": String(cString: model),
            "appLanguage": language,
            "systemLanguage": Locale.preferredLanguages.first ?? "",
        ]
    }

    /// Removes the user's name and paths from log lines before they leave the Mac (A5).
    public static func anonymize(_ lines: [String]) -> [String] {
        let home = NSHomeDirectory(), user = NSUserName(), full = NSFullUserName()
        return lines.map { line in
            var l = line.replacingOccurrences(of: home, with: "~")
            l = l.replacingOccurrences(of: "/Users/\(user)", with: "~")
            for name in [user, full] where name.count >= 3 { l = l.replacingOccurrences(of: name, with: "<user>") }
            return String(l.prefix(600))
        }
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}

public enum Reporter {
    public static let endpoint = "https://\(Limits.reportHost)/report"
    public enum Outcome: Equatable, Sendable { case sent(String), saved(URL), failed }

    /// Sends through NetGate (class `report`); if that fails, saves the report in Application Support/Fona/Reports.
    public static func send(_ r: Report, gate: NetGate = .shared) async -> Outcome {
        if let (resp, data) = try? await gate.post(endpoint, json: r.encoded(), .report), resp.head.status == 200 {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String ?? ""
            FileLog.shared.write("report sent: \(r.kind) #\(id.filter(\.isNumber))")
            return .sent(id)
        }
        return save(r).map { FileLog.shared.write("report saved (sending failed): \(r.kind)"); return .saved($0) } ?? .failed
    }

    public static func save(_ r: Report) -> URL? {
        let dir = LibraryStore.defaultDirectory.appendingPathComponent("Reports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("Fona-\(r.kind)-\(f.string(from: Date())).json")
        return (try? r.encoded().write(to: url)) != nil ? url : nil
    }
}
