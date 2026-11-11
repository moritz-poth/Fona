// P0-f spike: minimal HTTP/1.1 client on NWConnection that connects only to checked public addresses.
// Resolves itself (getaddrinfo), rejects private/special addresses, connects to the exact checked IP,
// sets TLS server name + hostname verification, re-checks the remote endpoint before sending, accepts
// "ICY 200 OK", follows ≤ 5 redirects (each re-checked), decodes chunked bodies, no proxy, identity encoding.
// Usage: p0f <url> [<url> …]  → one result line per URL.
import Foundation
import Network
import Security

enum GateError: Error, CustomStringConvertible {
    case scheme(String), noAddress(String), privateAddress(String), redirects, header(String), closed, timeout
    var description: String {
        switch self {
        case .scheme(let s): return "scheme \(s) not allowed"
        case .noAddress(let h): return "no address for \(h)"
        case .privateAddress(let a): return "private/special address \(a)"
        case .redirects: return "too many redirects"
        case .header(let s): return "bad header: \(s)"
        case .closed: return "connection closed early"
        case .timeout: return "timeout"
        }
    }
}

// shortcut: spike covers the main IANA blocks only; P1 implements the full table from PLAN §4.1 N4
func isPublic(_ ip: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, ip, &v4) == 1 {
        let a = UInt32(bigEndian: v4.s_addr)
        let blocked: [(UInt32, Int)] = [(0x00000000, 8), (0x0A000000, 8), (0x64400000, 10), (0x7F000000, 8),
            (0xA9FE0000, 16), (0xAC100000, 12), (0xC0000000, 24), (0xC0A80000, 16), (0xC6120000, 15), (0xE0000000, 4), (0xF0000000, 4)]
        return !blocked.contains { a >> (32 - $0.1) == $0.0 >> (32 - $0.1) }
    }
    if inet_pton(AF_INET6, ip, &v6) == 1 {
        let b = withUnsafeBytes(of: v6) { Array($0) }
        return b[0] & 0xE0 == 0x20 && !(b[0] == 0x20 && b[1] == 0x02) && !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0)
    }
    return false
}

func resolve(_ host: String) -> [String] {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
    defer { freeaddrinfo(res) }
    var out: [String] = [], p = res
    while let ai = p {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
            out.append(String(cString: buf))
        }
        p = ai.pointee.ai_next
    }
    return Array(Set(out)).sorted { !$0.contains(":") && $1.contains(":") }  // IPv4 first
}

final class Conn: @unchecked Sendable {
    let c: NWConnection
    init(_ c: NWConnection) { self.c = c }
    func start(timeout: Double) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            var done = false
            let finish: (Result<Void, Error>) -> Void = { r in if !done { done = true; k.resume(with: r) } }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(.success(()))
                case .failed(let e), .waiting(let e): finish(.failure(e))
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failure(GateError.timeout)) }
        }
    }
    func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.send(content: d, completion: .contentProcessed { e in e.map { k.resume(throwing: $0) } ?? k.resume() })
        }
    }
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { k in
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, e in
                if let e { k.resume(throwing: e) } else if let d, !d.isEmpty { k.resume(returning: d) }
                else { k.resume(returning: complete ? nil : Data()) }
            }
        }
    }
}

struct Response { var url: URL; var status: String; var headers: [String: String]; var body: Data; var address: String }

func fetch(_ start: URL, maxBody: Int) async throws -> Response {
    var url = start
    for _ in 0...5 {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw GateError.scheme(url.scheme ?? "none")
        }
        guard let host = url.host, !host.isEmpty else { throw GateError.noAddress("") }
        let addrs = resolve(host)
        guard !addrs.isEmpty else { throw GateError.noAddress(host) }
        if let bad = addrs.first(where: { !isPublic($0) }) { throw GateError.privateAddress(bad) }  // any bad → reject
        let ip = addrs[0]
        let port = UInt16(url.port ?? (scheme == "https" ? 443 : 80))
        let params: NWParameters
        if scheme == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(t, SecPolicyCreateSSL(true, host as CFString))
                done(SecTrustEvaluateWithError(t, nil))
            }, .global())
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
        params.preferNoProxies = true
        let conn = Conn(NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: params))
        defer { conn.c.cancel() }
        try await conn.start(timeout: 10)
        // re-check the peer before the first byte leaves
        if case .hostPort(let h, _)? = conn.c.currentPath?.remoteEndpoint {
            let peer = "\(h)".components(separatedBy: "%")[0]
            guard isPublic(peer) else { throw GateError.privateAddress(peer) }
        }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: Fona-spike/0\r\nIcy-MetaData: 1\r\n"
            + "Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
        try await conn.send(Data(req.utf8))
        var buf = Data()
        let deadline = Date().addingTimeInterval(15)
        while buf.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buf.count <= 16_384 else { throw GateError.header("too long") }
            guard Date() < deadline else { throw GateError.timeout }
            guard let d = try await conn.receive() else { throw GateError.closed }
            buf.append(d)
        }
        let split = buf.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buf[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var body = Data(buf[split.upperBound...])
        let status = head[0]
        guard status.hasPrefix("HTTP/1.") || status.hasPrefix("ICY ") else { throw GateError.header(status) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let code = Int(status.split(separator: " ").dropFirst().first ?? "") ?? 0
        if (300..<400).contains(code), let loc = headers["location"], let next = URL(string: loc, relativeTo: url)?.absoluteURL {
            url = next
            continue
        }
        if let ce = headers["content-encoding"], ce.lowercased() != "identity" { throw GateError.header("encoding \(ce)") }
        let chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
        while body.count < maxBody + (chunked ? 4096 : 0), Date() < deadline.addingTimeInterval(10) {
            guard let d = try await conn.receive() else { break }
            body.append(d)
        }
        if chunked { body = dechunk(body) }
        return Response(url: url, status: status, headers: headers, body: body.prefix(maxBody), address: ip)
    }
    throw GateError.redirects
}

// shortcut: decodes complete chunks only (spike reads a prefix); P1 streams chunk by chunk
func dechunk(_ d: Data) -> Data {
    var out = Data(), i = d.startIndex
    while let nl = d[i...].range(of: Data("\r\n".utf8)) {
        let sizeText = String(decoding: d[i..<nl.lowerBound], as: UTF8.self).split(separator: ";")[0]
        guard let size = Int(sizeText, radix: 16), size > 0 else { break }
        let start = nl.upperBound, end = start + size
        guard end <= d.endIndex else { out.append(d[start...]); break }
        out.append(d[start..<end]); i = min(end + 2, d.endIndex)
    }
    return out
}

func kind(_ b: Data) -> String {
    let a = [UInt8](b.prefix(16_384))
    if a.starts(with: Array("#EXTM3U".utf8)) { return "HLS playlist" }
    if a.starts(with: Array("[playlist]".utf8)) { return "PLS playlist" }
    if a.count > 940, (0..<5).allSatisfy({ a[$0 * 188] == 0x47 }) { return "MPEG-TS" }
    for i in 0..<max(0, a.count - 1) where a[i] == 0xFF && a[i + 1] & 0xE0 == 0xE0 {
        return a[i + 1] & 0x06 == 0 ? "ADTS sync @\(i)" : "MP3 sync @\(i)"
    }
    return "unknown"
}

let urls = CommandLine.arguments.dropFirst()
for s in urls {
    let t0 = Date()
    do {
        let r = try await fetch(URL(string: s)!, maxBody: 32_768)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("OK   \(r.status) | \(r.headers["content-type"] ?? "-") | metaint=\(r.headers["icy-metaint"] ?? "-") | chunked=\(r.headers["transfer-encoding"] ?? "-") | \(r.body.count) B \(kind(r.body)) | ip=\(r.address) | \(ms) ms | \(r.url.host ?? "")")
    } catch {
        print("FAIL \(error) | \(s)")
    }
}
