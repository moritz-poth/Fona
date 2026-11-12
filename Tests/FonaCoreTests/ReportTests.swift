import Foundation
import Testing
@testable import FonaCore

/// The report must pass the worker's `validate()` (Mountpoint worker/src/index.js) and contain nothing personal.
@Test func selfTestReportFitsWorkerRules() throws {
    let checks = CheckCatalog.runAll()
    let r = Report(kind: "selftest", app: "0.1.0", build: "1", date: ISO8601DateFormatter().string(from: Date()),
                   system: Report.systemInfo(language: "de"), results: Report.results(from: checks, seconds: 2.5),
                   durationSeconds: 2.5, log: Report.anonymize((0..<400).map { "line \($0) " + String(repeating: "x", count: 700) }.suffix(300).map { $0 }),
                   note: nil, contact: nil)
    #expect(r.product.range(of: "^[a-z-]{1,40}$", options: .regularExpression) != nil)
    #expect(r.app.range(of: "^[0-9A-Za-z.\\-]{1,32}$", options: .regularExpression) != nil)
    #expect(r.build.count <= 16 && r.date.count <= 40)
    #expect(r.system.count <= 40 && r.system.allSatisfy { $0.key.count <= 40 && $0.value.count <= 200 })
    #expect(r.results.count <= 100)
    #expect(r.results.allSatisfy { $0.id.count <= 40 && $0.title.count <= 100 && $0.detail.count <= 1000 && ["pass", "fail", "skip"].contains($0.status) })
    #expect(r.log.count <= 300 && r.log.allSatisfy { $0.count <= 600 })
    #expect(r.encoded().count < 1_000_000)
    #expect(r.results.allSatisfy { $0.status == "pass" })
}

@Test func anonymizeRemovesUserAndPaths() {
    let lines = Report.anonymize(["\(NSHomeDirectory())/Library/x", "user \(NSUserName()) did y", "/Users/\(NSUserName())/Music"])
    #expect(lines.allSatisfy { !$0.contains(NSUserName()) })
    #expect(lines[0] == "~/Library/x")
}

@Test func fileLogRotatesAndSanitizes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fona-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = FileLog(directory: dir)
    log.write("hello\u{202E}world\nnext")
    #expect(log.tail().last?.hasSuffix("helloworld next") == true)
    for i in 0..<12_000 { log.write("filler \(i) " + String(repeating: "z", count: 80)) }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Fona.old.log").path))
    let size = (try FileManager.default.attributesOfItem(atPath: log.file.path)[.size] as? Int) ?? 0
    #expect(size < FileLog.maxBytes + 10_000)
}
