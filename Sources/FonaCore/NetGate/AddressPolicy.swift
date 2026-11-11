import Foundation

/// A resolved IP address in binary form (PLAN §4.1 N4: rules work on bytes, never on text).
public struct IPAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]  // 4 or 16
    public var isV4: Bool { bytes.count == 4 }

    public init?(_ text: String) {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    public var description: String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { p in _ = inet_ntop(isV4 ? AF_INET : AF_INET6, p.baseAddress, &buf, socklen_t(buf.count)) }
        return String(cString: buf)
    }
}

public enum AddressPolicy {
    /// IPv4 special-purpose blocks (IANA registry), all blocked.
    static let blockedV4: [(prefix: [UInt8], bits: Int)] = [
        ([0, 0, 0, 0], 8), ([10, 0, 0, 0], 8), ([100, 64, 0, 0], 10), ([127, 0, 0, 0], 8), ([169, 254, 0, 0], 16),
        ([172, 16, 0, 0], 12), ([192, 0, 0, 0], 24), ([192, 0, 2, 0], 24), ([192, 88, 99, 0], 24), ([192, 168, 0, 0], 16),
        ([198, 18, 0, 0], 15), ([198, 51, 100, 0], 24), ([203, 0, 113, 0], 24), ([224, 0, 0, 0], 4), ([240, 0, 0, 0], 4),
    ]
    /// IPv6: only global unicast 2000::/3 is allowed at all, minus these blocks. Everything with an embedded
    /// IPv4 (::ffff:, ::/96, 64:ff9b::, 6to4 2002::, Teredo 2001::) is therefore blocked as a whole.
    static let blockedV6InGlobal: [(prefix: [UInt8], bits: Int)] = [
        ([0x20, 0x01, 0x00, 0x00], 32),        // Teredo
        ([0x20, 0x01, 0x00, 0x02, 0, 0], 48),  // benchmarking
        ([0x20, 0x01, 0x00, 0x10], 28),        // ORCHID
        ([0x20, 0x01, 0x00, 0x20], 28),        // ORCHIDv2
        ([0x20, 0x01, 0x0d, 0xb8], 32),        // documentation
        ([0x20, 0x02], 16),                    // 6to4
        ([0x3f, 0xff], 20),                    // documentation (RFC 9637)
    ]

    static func matches(_ b: [UInt8], _ prefix: [UInt8], _ bits: Int) -> Bool {
        var left = bits
        for i in 0..<prefix.count where left > 0 {
            let take = min(8, left)
            let mask: UInt8 = take == 8 ? 0xFF : UInt8(0xFF << (8 - take) & 0xFF)
            if b[i] & mask != prefix[i] & mask { return false }
            left -= take
        }
        return true
    }

    public static func isPublic(_ a: IPAddress) -> Bool {
        if a.isV4 { return !blockedV4.contains { matches(a.bytes, $0.prefix, $0.bits) } }
        guard a.bytes[0] & 0xE0 == 0x20 else { return false }
        return !blockedV6InGlobal.contains { matches(a.bytes, $0.prefix, $0.bits) }
    }

    /// N4: every resolved address must be public; the first one is used for the connection.
    public static func choose(_ addresses: [IPAddress]) -> Result<IPAddress, Rejection> {
        guard !addresses.isEmpty else { return .failure(.noAddress) }
        guard addresses.allSatisfy(isPublic) else { return .failure(.privateAddress) }
        return .success(addresses.first(where: \.isV4) ?? addresses[0])
    }
}

/// Name resolution behind a protocol so the check catalogue can feed hostile answers (DNS rebinding) without a network.
public protocol Resolver: Sendable {
    func resolve(_ host: String) -> [IPAddress]
}

public struct SystemResolver: Resolver {
    public init() {}
    public func resolve(_ host: String) -> [IPAddress] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [IPAddress] = [], p = res
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0,
               let ip = IPAddress(String(cString: buf).components(separatedBy: "%")[0]), !out.contains(ip) {
                out.append(ip)
            }
            p = ai.pointee.ai_next
        }
        return out
    }
}
