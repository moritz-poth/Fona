import CryptoKit
import Foundation

/// Version from a release tag like "v1.0.0-beta.7". Final releases rank above their betas (as in Mountpoint).
public struct AppVersion: Comparable, Equatable, Sendable {
    public let numbers: [Int]
    public let beta: Int?

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1)
        guard let first = parts.first, first.count <= 20 else { return nil }
        let nums = first.split(separator: ".", omittingEmptySubsequences: false).map { ResponseHead.digits(String($0)) }
        guard !nums.isEmpty, nums.count <= 4, !nums.contains(nil) else { return nil }
        numbers = nums.map { $0! }
        if parts.count == 2 {
            guard let b = ResponseHead.digits(parts[1].lowercased().replacingOccurrences(of: "beta.", with: "")) else { return nil }
            beta = b
        } else {
            beta = nil
        }
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.numbers.count, b.numbers.count)
        let x = a.numbers + Array(repeating: 0, count: n - a.numbers.count)
        let y = b.numbers + Array(repeating: 0, count: n - b.numbers.count)
        if x != y { return x.lexicographicallyPrecedes(y) }
        switch (a.beta, b.beta) {
        case let (p?, q?): return p < q
        case (_?, nil): return true
        default: return false
        }
    }
}

public struct Release: Equatable, Sendable {
    public let tag: String
    public let zip: String
    public let signature: String?
    /// Asset `Fona-<version>.manual`: install by hand (after a key loss). Text and link are fixed in the app.
    public let manual: Bool
    public let prerelease: Bool

    public static let releasesPage = "https://github.com/moritz-poth/Fona/releases"
    public static let api = "https://api.github.com/repos/moritz-poth/Fona/releases?per_page=20"
}

public enum UpdateKey {
    /// Public half of "Fona update key" (`swift scripts/update-key.swift public`). Never replace it: installed apps
    /// trust only this key. Key-loss procedure: README / CLAUDE.md.
    public static let publicKey = "SpAnmbmghGy/wHyO7fOz66XZaAwQDyF5e09E2fQQmW8="

    public static func verify(_ zip: Data, signatureBase64: Data) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let text = String(data: signatureBase64, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let sig = Data(base64Encoded: text) else { return false }
        return key.isValidSignature(sig, for: zip)
    }
}

public enum UpdateCheck {
    /// Newest non-draft release with `Fona-<version>.zip` (and its `.sig`). Download URLs must stay on GitHub.
    public static func newestRelease(fromJSON data: Data, includePrereleases: Bool) -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct R: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool?; let assets: [Asset] }
        guard data.count <= Limits.directoryBytes, let list = try? JSONDecoder().decode([R].self, from: data) else { return nil }
        let onGitHub = { (u: String) in u.hasPrefix("https://github.com/moritz-poth/Fona/releases/download/") }
        return list.prefix(50)
            .filter { !$0.draft && AppVersion($0.tag_name) != nil && (includePrereleases || $0.prerelease != true) }
            .compactMap { r -> (AppVersion, Release)? in
                let version = String(r.tag_name.dropFirst(r.tag_name.hasPrefix("v") ? 1 : 0))
                guard let zip = r.assets.first(where: { $0.name == "Fona-\(version).zip" }), onGitHub(zip.browser_download_url) else { return nil }
                let sig = r.assets.first { $0.name == zip.name + ".sig" && onGitHub($0.browser_download_url) }?.browser_download_url
                let manual = r.assets.contains { $0.name == "Fona-\(version).manual" }
                guard sig != nil || manual else { return nil }
                return (AppVersion(r.tag_name)!, Release(tag: r.tag_name, zip: zip.browser_download_url, signature: sig,
                                                          manual: manual, prerelease: r.prerelease == true))
            }
            .max { $0.0 < $1.0 }?.1
    }

    /// Where the app hands a verified download to FonaUpdater (inside the app's container; fixed names, PLAN §7).
    public static var pendingDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Updates")
    }
}
