import Foundation

/// What a response claims to be, derived from Content-Type. Used only for routing and messages (PLAN H8);
/// the bytes decide (Sniffer).
public enum ContentKind: Equatable, Sendable {
    case audio, hlsPlaylist, plainPlaylist, mpegTS, json, zip, unknown
}

public struct ResponseHead: Equatable, Sendable {
    public let isICY: Bool
    public let status: Int
    public let headers: [String: String]  // lower-case names
    public let headerLength: Int          // bytes up to and including the blank line

    public func value(_ name: String) -> String? { headers[name] }
    public var location: String? { headers["location"] }
    public var isRedirect: Bool { [301, 302, 303, 307, 308].contains(status) }
    public var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false }
    public var contentLength: Int? { headers["content-length"].flatMap(Self.digits) }
    public var icyMetaInt: Int? { headers["icy-metaint"].flatMap(Self.digits) }
    public var nominalKbps: Int? {
        headers["icy-br"].flatMap { Self.digits(String($0.split(separator: ",").first ?? "")) }.flatMap { (8...1000).contains($0) ? $0 : nil }
    }

    /// Server numbers: plain decimal digits only (Int("-5") or Int("+5") would be accepted otherwise).
    static func digits(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 12, t.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(t)
    }
}

public enum HeadParser {
    /// Parses status line + headers. Accepts CRLF and bare LF line ends (P0-f: some Icecast servers mix them)
    /// and "ICY 200 OK" (Shoutcast v1). Returns nil while the blank line has not arrived yet.
    public static func parse(_ data: Data) -> Result<ResponseHead, Rejection>? {
        let b = [UInt8](data.prefix(Limits.maxHeaderBytes + 4))
        var end: Int?
        var i = 0
        while i < b.count {
            if b[i] == 0x0A {
                if i + 1 < b.count, b[i + 1] == 0x0A { end = i + 2; break }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { end = i + 3; break }
            }
            i += 1
        }
        guard let end else { return data.count > Limits.maxHeaderBytes ? .failure(.headerTooLong) : nil }
        guard end <= Limits.maxHeaderBytes else { return .failure(.headerTooLong) }
        let text = String(decoding: b[..<end], as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard let first = lines.first else { return .failure(.badStatusLine) }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]), (100...599).contains(code) else { return .failure(.badStatusLine) }
        let isICY: Bool
        if parts[0] == "ICY" { isICY = true } else if parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0" { isICY = false }
        else { return .failure(.badStatusLine) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return .failure(.badStatusLine) }
            if name == "content-length", let old = headers[name], old != value { return .failure(.badStatusLine) }  // smuggling
            headers[name] = value
        }
        return .success(ResponseHead(isICY: isICY, status: code, headers: headers, headerLength: end))
    }

    /// N6 + N7 checks on a final (non-redirect) head for the given request class.
    public static func check(_ h: ResponseHead, _ cls: RequestClass) -> Result<ContentKind, Rejection> {
        guard (200...299).contains(h.status) else { return .failure(.httpStatus(h.status)) }
        if let enc = h.value("content-encoding")?.lowercased(), !enc.isEmpty, enc != "identity" { return .failure(.contentEncoding) }
        if let te = h.value("transfer-encoding")?.lowercased(), !te.isEmpty, te != "chunked", te != "identity" {
            return .failure(.contentEncoding)
        }
        if let max = cls.maxBody, let len = h.contentLength, len > max { return .failure(.bodyTooLarge) }
        let kind: ContentKind
        switch classify(h.value("content-type")) {
        case .failure(let r): return .failure(r)
        case .success(let k): kind = k
        }
        let allowed: Set<ContentKind>
        switch cls {
        case .stream, .playlist: allowed = [.audio, .hlsPlaylist, .plainPlaylist, .mpegTS, .unknown]
        case .segment: allowed = [.audio, .mpegTS, .unknown]
        case .directory: allowed = [.json]
        case .update: allowed = [.json, .zip, .unknown]  // .sig files come as octet-stream
        case .report: allowed = [.json, .unknown]
        }
        return allowed.contains(kind) ? .success(kind) : .failure(.blockedContentType)
    }

    /// Content-Type → kind. Blocklist (H8): web pages, images, programs, archives, ogg, video except MPEG-TS.
    public static func classify(_ contentType: String?) -> Result<ContentKind, Rejection> {
        let t = (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch t {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
            return .success(.hlsPlaylist)  // .m3u and .m3u8 share these types; the first line decides
        case "audio/x-scpls", "application/pls+xml": return .success(.plainPlaylist)
        case "video/mp2t", "video/mpeg": return .success(.mpegTS)
        case "application/json": return .success(.json)
        case "application/zip", "application/x-zip-compressed": return .success(.zip)
        case "application/ogg", "audio/ogg", "audio/opus", "audio/flac", "audio/x-flac": return .failure(.blockedContentType)
        case "", "application/octet-stream", "binary/octet-stream", "text/plain": return .success(.unknown)
        default:
            if t.hasPrefix("audio/") { return .success(.audio) }
            return .failure(.blockedContentType)  // text/html, image/*, video/*, application/x-* …
        }
    }
}
