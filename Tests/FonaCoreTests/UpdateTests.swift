import CryptoKit
import Foundation
import Testing
@testable import FonaCore

@Test func versionOrder() {
    #expect(AppVersion("v0.1.0")! < AppVersion("0.2.0-beta.1")!)
    #expect(AppVersion("0.2.0-beta.1")! < AppVersion("0.2.0-beta.2")!)
    #expect(AppVersion("0.2.0-beta.9")! < AppVersion("0.2.0")!)
    #expect(AppVersion("1.0") == AppVersion("1.0.0"))
    #expect(AppVersion("v1.-2") == nil && AppVersion("+1.0") == nil && AppVersion("1.0-rc") == nil)
}

func releasesJSON(_ entries: [(tag: String, pre: Bool, assets: [String], host: String)]) -> Data {
    let list = entries.map { e in
        ["tag_name": e.tag, "draft": false, "prerelease": e.pre,
         "assets": e.assets.map { ["name": $0, "browser_download_url": "\(e.host)/\(e.tag)/\($0)"] }] as [String: Any]
    }
    return try! JSONSerialization.data(withJSONObject: list)
}

@Test func newestReleaseRules() {
    let gh = "https://github.com/moritz-poth/Fona/releases/download"
    let data = releasesJSON([
        ("v0.2.0", false, ["Fona-0.2.0.zip", "Fona-0.2.0.zip.sig"], gh),
        ("v0.3.0-beta.1", true, ["Fona-0.3.0-beta.1.zip", "Fona-0.3.0-beta.1.zip.sig"], gh),
        ("v0.4.0", false, ["Fona-0.4.0.zip"], gh),                                         // unsigned → ignored
        ("v0.5.0", false, ["Fona-0.5.0.zip", "Fona-0.5.0.zip.sig"], "https://evil.example.com"),  // off GitHub → ignored
        ("v0.6.0", false, ["Other-0.6.0.zip", "Other-0.6.0.zip.sig"], gh),                 // wrong asset name
    ])
    #expect(UpdateCheck.newestRelease(fromJSON: data, includePrereleases: false)?.tag == "v0.2.0")
    #expect(UpdateCheck.newestRelease(fromJSON: data, includePrereleases: true)?.tag == "v0.3.0-beta.1")
    let manual = releasesJSON([("v0.7.0", false, ["Fona-0.7.0.zip", "Fona-0.7.0.manual"], gh)])
    #expect(UpdateCheck.newestRelease(fromJSON: manual, includePrereleases: false)?.manual == true)
    #expect(UpdateCheck.newestRelease(fromJSON: Data("not json".utf8), includePrereleases: true) == nil)
}

@Test func signatureCheck() {
    let other = Curve25519.Signing.PrivateKey()
    let zip = Data("zip bytes".utf8)
    let foreign = Data(try! other.signature(for: zip).base64EncodedString().utf8)
    #expect(!UpdateKey.verify(zip, signatureBase64: foreign))       // signed with another key
    #expect(!UpdateKey.verify(zip, signatureBase64: Data("garbage".utf8)))
}

/// The real path: GitHub API → newest release → zip + sig through NetGate (redirect to the asset host) → signature.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FONA_LIVE"] == "1"))
func liveUpdatePath() async throws {
    let (_, json) = try await NetGate.shared.fetch(Release.api, .update)
    let r = try #require(UpdateCheck.newestRelease(fromJSON: json, includePrereleases: true))
    let sig = try await NetGate.shared.fetch(try #require(r.signature), .update).1
    let zip = try await NetGate.shared.fetch(r.zip, .update).1
    #expect(zip.count > 1_000_000)
    #expect(UpdateKey.verify(zip, signatureBase64: sig))
    #expect(UpdateCheck.newestRelease(fromJSON: json, includePrereleases: false) == nil || !r.prerelease)
}
