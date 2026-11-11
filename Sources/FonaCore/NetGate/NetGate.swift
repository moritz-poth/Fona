import Foundation
import Network
import Security

/// The only place in Fona that talks to the network (PLAN §4.1). HTTP/1.1 on NWConnection:
/// resolves names itself, connects only to a checked public address, sets TLS server name and verifies
/// the certificate against the host name, re-checks the peer before the first byte is sent, no proxies,
/// no compression, no cookies, no cache, every redirect re-checked.
public final class NetGate: @unchecked Sendable {
    public static let shared = NetGate()

    let resolver: Resolver
    let userAgent: String

    public init(resolver: Resolver = SystemResolver(), userAgent: String = "Fona/\(FonaVersion.string)") {
        self.resolver = resolver
        self.userAgent = userAgent
    }

    /// An open response: head plus the body as a stream of decoded (de-chunked) bytes.
    public struct Response: Sendable {
        public let url: CheckedURL
        public let head: ResponseHead
        public let kind: ContentKind
        public let body: AsyncThrowingStream<Data, Error>
        public let cancel: @Sendable () -> Void
    }

    public func open(_ text: String, _ cls: RequestClass) async throws -> Response {
        var url = try URLPolicy.check(text, cls).get()
        var visited = [url.text]
        while true {
            let conn = try await connect(url)
            do {
                try await conn.send(request(url, cls))
                let (head, rest) = try await readHead(conn)
                if head.isRedirect, let loc = head.location {
                    conn.cancel()
                    url = try URLPolicy.redirect(from: url, location: loc, cls, visited: visited).get()
                    visited.append(url.text)
                    continue
                }
                let kind = try HeadParser.check(head, cls).get()
                return Response(url: url, head: head, kind: kind, body: bodyStream(conn, head, rest, cls), cancel: { conn.cancel() })
            } catch {
                conn.cancel()
                throw error
            }
        }
    }

    /// Whole body for small, bounded classes (directory, update, report, playlist, segment).
    public func fetch(_ text: String, _ cls: RequestClass) async throws -> (Response, Data) {
        precondition(cls.maxBody != nil, "fetch is only for bounded request classes")
        let r = try await open(text, cls)
        var data = Data()
        for try await piece in r.body { data.append(piece) }
        return (r, data)
    }

    func request(_ url: CheckedURL, _ cls: RequestClass) -> Data {
        var r = "GET \(url.pathAndQuery) HTTP/1.1\r\nHost: \(url.hostHeader)\r\nUser-Agent: \(userAgent)\r\n"
        r += "Accept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n"
        if cls == .stream { r += "Icy-MetaData: 1\r\n" }
        return Data((r + "\r\n").utf8)
    }

    // MARK: connection

    func connect(_ url: CheckedURL) async throws -> Connection {
        let addresses = url.ipLiteral.map { [$0] } ?? resolver.resolve(url.host)
        let ip = try AddressPolicy.choose(addresses).get()
        let params: NWParameters
        if url.isHTTPS {
            let tls = NWProtocolTLS.Options()
            let host = url.host
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(t, SecPolicyCreateSSL(true, host as CFString))
                done(SecTrustEvaluateWithError(t, nil))
            }, .global(qos: .userInitiated))
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
        params.preferNoProxies = true
        let c = Connection(NWConnection(host: NWEndpoint.Host(ip.description), port: NWEndpoint.Port(rawValue: url.port)!, using: params))
        try await c.start(timeout: Limits.connectTimeout)
        // the peer we actually reached must still be the checked public address
        guard case .hostPort(let h, _)? = c.nw.currentPath?.remoteEndpoint,
              let peer = IPAddress("\(h)".components(separatedBy: "%")[0]), AddressPolicy.isPublic(peer) else {
            c.cancel()
            throw Rejection.privateAddress
        }
        return c
    }

    func readHead(_ c: Connection) async throws -> (ResponseHead, Data) {
        var buf = Data()
        let deadline = Date().addingTimeInterval(Limits.headerTimeout)
        while true {
            if let parsed = HeadParser.parse(buf) {
                let head = try parsed.get()
                return (head, Data(buf.dropFirst(head.headerLength)))
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw Rejection.headerTimeout }
            guard let piece = try await c.receive(timeout: left) else { throw Rejection.badStatusLine }
            buf.append(piece)
        }
    }

    func bodyStream(_ c: Connection, _ head: ResponseHead, _ first: Data, _ cls: RequestClass) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var chunked = head.isChunked ? ChunkedDecoder() : nil
                var total = 0
                let started = Date()
                var windowStart = Date(), windowBytes = 0
                let minBytesPerSec = Double(head.nominalKbps ?? 32) * 1000 / 8 * Limits.minThroughputShare
                func emit(_ raw: Data) throws -> Bool {
                    var data = raw
                    if chunked != nil { data = try chunked!.feed(raw) }
                    total += data.count
                    if let max = cls.maxBody, total > max { throw Rejection.bodyTooLarge }
                    if !data.isEmpty { cont.yield(data) }
                    if let len = head.contentLength, chunked == nil, total >= len { return false }
                    return !(chunked?.finished ?? false)
                }
                do {
                    var more = first.isEmpty ? true : try emit(first)
                    while more {
                        try Task.checkCancellation()
                        guard let piece = try await c.receive(timeout: Limits.stallTimeout) else { break }
                        more = try emit(piece)
                        // slowloris guard for endless streams: after 10 s, ≥ 25 % of the nominal bitrate per 30 s window
                        if cls == .stream, Date().timeIntervalSince(started) > 10 {
                            windowBytes += piece.count
                            if Date().timeIntervalSince(windowStart) >= Limits.throughputWindow {
                                if Double(windowBytes) / Limits.throughputWindow < minBytesPerSec { throw Rejection.tooSlow }
                                windowStart = Date(); windowBytes = 0
                            }
                        }
                    }
                    if let cd = chunked, !cd.finished { throw Rejection.badChunk }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
                c.cancel()
            }
            cont.onTermination = { _ in task.cancel(); c.cancel() }
        }
    }
}

public enum FonaVersion {
    public static let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
}

/// Thin async wrapper around NWConnection.
final class Connection: @unchecked Sendable {
    let nw: NWConnection
    private let lock = NSLock()
    private var cancelled = false

    init(_ nw: NWConnection) { self.nw = nw }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = Once()
            nw.stateUpdateHandler = { st in
                switch st {
                case .ready: once.run { k.resume() }
                case .failed(let e), .waiting(let e): once.run { k.resume(throwing: Self.map(e)) }
                case .cancelled: once.run { k.resume(throwing: Rejection.network) }
                default: break
                }
            }
            nw.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { k.resume(throwing: Rejection.connectTimeout) } }
        }
    }

    func send(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            nw.send(content: d, completion: .contentProcessed { e in
                if let e { k.resume(throwing: Self.map(e)) } else { k.resume() }
            })
        }
    }

    /// nil = connection closed by the peer.
    func receive(timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
            let once = Once()
            nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { d, _, complete, e in
                if let d, !d.isEmpty { once.run { k.resume(returning: d) } }
                else if let e { once.run { k.resume(throwing: Self.map(e)) } }
                else if complete { once.run { k.resume(returning: nil) } }
                else { once.run { k.resume(returning: Data()) } }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.run { k.resume(throwing: Rejection.stalled) } }
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if !cancelled { cancelled = true; nw.cancel() }
    }

    static func map(_ e: NWError) -> Error {
        if case .tls = e { return Rejection.tls }
        if case .dns = e { return Rejection.noAddress }
        return Rejection.network
    }
}

/// Runs a closure at most once (continuations must be resumed exactly once).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { f() }
    }
}
