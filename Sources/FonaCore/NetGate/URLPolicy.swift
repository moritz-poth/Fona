import Foundation

/// A URL that passed N1–N3. The request is rebuilt only from these parts (no second URL parser decides later).
public struct CheckedURL: Hashable, Sendable {
    public let scheme: String      // "http" | "https"
    public let host: String        // lower-case name or IP literal (without brackets)
    public let port: UInt16
    public let pathAndQuery: String
    public let ipLiteral: IPAddress?

    public var isHTTPS: Bool { scheme == "https" }
    public var hostHeader: String {
        let h = ipLiteral.map { $0.isV4 ? host : "[\(host)]" } ?? host
        let defaultPort: UInt16 = isHTTPS ? 443 : 80
        return port == defaultPort ? h : "\(h):\(port)"
    }
    public var text: String { "\(scheme)://\(hostHeader)\(pathAndQuery)" }
}

public enum URLPolicy {
    static let blockedSuffixes = [".local", ".localhost", ".home.arpa", ".internal", ".lan", ".intranet", ".corp", ".home"]

    /// N1–N3 (+ class host list). Pure: no network.
    public static func check(_ text: String, _ cls: RequestClass, relativeTo base: CheckedURL? = nil) -> Result<CheckedURL, Rejection> {
        guard text.utf8.count <= Limits.maxURLLength else { return .failure(.urlTooLong) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isNewline || $0 == "\0" }) else { return .failure(.badURL) }
        let baseURL = base.flatMap { URL(string: $0.text) }
        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return .failure(.badURL) }
        let scheme = (comps.scheme ?? "").lowercased()
        guard scheme == "https" || (scheme == "http" && cls.allowsHTTP) else { return .failure(.scheme(scheme)) }
        guard comps.user == nil, comps.password == nil else { return .failure(.credentialsInURL) }
        guard let rawHost = comps.percentEncodedHost, !rawHost.isEmpty else { return .failure(.badURL) }
        guard !rawHost.contains("%") else { return .failure(.hostName) }  // percent-encoded host or IPv6 zone id

        var host = rawHost.lowercased()
        var literal: IPAddress?
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard let ip = IPAddress(host), !ip.isV4 else { return .failure(.hostName) }
            literal = ip
        } else if let ip = strictIPv4(host) {
            literal = ip
        } else {
            guard validName(host) else { return .failure(.hostName) }
        }
        if let literal, !AddressPolicy.isPublic(literal) { return .failure(.privateAddress) }
        guard cls.hostAllowed(host) else { return .failure(.hostNotAllowed) }

        let port = comps.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return .failure(.badURL) }
        var path = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery { path += "?" + q }
        guard path.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return .failure(.badURL) }
        return .success(CheckedURL(scheme: scheme, host: host, port: UInt16(port), pathAndQuery: path, ipLiteral: literal))
    }

    /// Only plain dotted-quad decimal counts as an IPv4 literal; every other numeric form is rejected as a name.
    static func strictIPv4(_ h: String) -> IPAddress? {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isASCIIDigit) && !(p.count > 1 && p.first == "0") && Int(p)! <= 255
        }) else { return nil }
        return IPAddress(h)
    }

    /// N3 name rules: ASCII LDH labels (punycode allowed), at least two labels, alphabetic top-level label,
    /// no trailing dot, not a local-only suffix.
    static func validName(_ h: String) -> Bool {
        guard h.count <= 253, !h.hasSuffix("."), h != "localhost" else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard (1...63).contains(l.count), l.first != "-", l.last != "-",
                  l.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        guard let tld = labels.last, tld.contains(where: \.isLetter) else { return false }  // 127.1, 0x7f.1 …
        return !blockedSuffixes.contains { h.hasSuffix($0) }
    }

    /// N5: one redirect step. `visited` holds the texts of every URL in the chain so far.
    public static func redirect(from: CheckedURL, location: String, _ cls: RequestClass, visited: [String]) -> Result<CheckedURL, Rejection> {
        guard visited.count <= Limits.maxRedirects else { return .failure(.tooManyRedirects) }
        switch check(location, cls, relativeTo: from) {
        case .failure(.scheme("http")) where from.isHTTPS: return .failure(.downgrade)
        case .failure(let r): return .failure(r)
        case .success(let next):
            if visited.contains(next.text) { return .failure(.redirectLoop) }
            return .success(next)
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
