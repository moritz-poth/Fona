import Foundation

/// Every reason NetGate refuses something. Each case has a plain-language text in German and English
/// (`Messages`); a test makes sure none is missing. Reports and the log only ever see `code`.
public enum Rejection: Error, Equatable, Sendable {
    case badURL
    case scheme(String)
    case credentialsInURL
    case urlTooLong
    case hostName
    case hostNotAllowed
    case noAddress
    case privateAddress
    case tooManyRedirects
    case redirectLoop
    case downgrade
    case headerTooLong
    case headerTimeout
    case badStatusLine
    case httpStatus(Int)
    case contentEncoding
    case blockedContentType
    case bodyTooLarge
    case badChunk
    case notAudio
    case connectTimeout
    case stalled
    case tooSlow
    case tls
    case network

    /// Stable short code for logs and reports (never contains URLs or names).
    public var code: String {
        switch self {
        case .badURL: return "bad-url"
        case .scheme: return "scheme"
        case .credentialsInURL: return "credentials"
        case .urlTooLong: return "url-too-long"
        case .hostName: return "host-name"
        case .hostNotAllowed: return "host-not-allowed"
        case .noAddress: return "no-address"
        case .privateAddress: return "private-address"
        case .tooManyRedirects: return "too-many-redirects"
        case .redirectLoop: return "redirect-loop"
        case .downgrade: return "downgrade"
        case .headerTooLong: return "header-too-long"
        case .headerTimeout: return "header-timeout"
        case .badStatusLine: return "bad-status-line"
        case .httpStatus(let c): return "http-\(c)"
        case .contentEncoding: return "content-encoding"
        case .blockedContentType: return "blocked-content-type"
        case .bodyTooLarge: return "body-too-large"
        case .badChunk: return "bad-chunk"
        case .notAudio: return "not-audio"
        case .connectTimeout: return "connect-timeout"
        case .stalled: return "stalled"
        case .tooSlow: return "too-slow"
        case .tls: return "tls"
        case .network: return "network"
        }
    }

    /// One representative of every case, for the completeness test of `Messages`.
    public static let allExamples: [Rejection] = [
        .badURL, .scheme("file"), .credentialsInURL, .urlTooLong, .hostName, .hostNotAllowed, .noAddress, .privateAddress,
        .tooManyRedirects, .redirectLoop, .downgrade, .headerTooLong, .headerTimeout, .badStatusLine, .httpStatus(404),
        .contentEncoding, .blockedContentType, .bodyTooLarge, .badChunk, .notAudio, .connectTimeout, .stalled, .tooSlow,
        .tls, .network,
    ]
}
