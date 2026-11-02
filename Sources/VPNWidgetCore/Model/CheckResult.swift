import Foundation

/// The outcome of checking the service behind a tunnel. It holds only short
/// descriptions, never addresses, so the menu and the logs cannot show where a
/// request went.
public struct CheckResult: Equatable, Sendable {
    /// "ok", a short failure, or empty when not checked.
    public var dns: String
    /// "HTTP 200", or a short failure.
    public var http: String
    public var dnsMS: Int
    /// The TCP connect time: the first hop's round trip.
    public var connectMS: Int
    /// The time until the first answer, with TLS and the server's work.
    public var totalMS: Int
    public var httpStatus: Int?
    public var ok: Bool
    /// A failure too recent to count yet; see `FailureTracker`.
    public var doubtful: Bool

    public init(
        dns: String = "",
        http: String = "",
        dnsMS: Int = 0,
        connectMS: Int = 0,
        totalMS: Int = 0,
        httpStatus: Int? = nil,
        ok: Bool = false,
        doubtful: Bool = false
    ) {
        self.dns = dns
        self.http = http
        self.dnsMS = dnsMS
        self.connectMS = connectMS
        self.totalMS = totalMS
        self.httpStatus = httpStatus
        self.ok = ok
        self.doubtful = doubtful
    }

    /// A failure that counts.
    public var failed: Bool { !ok && !doubtful }

    public var description: String {
        var parts: [String] = []
        if !dns.isEmpty { parts.append("DNS \(dns)") }
        if !http.isEmpty { parts.append(http) }
        if connectMS > 0 { parts.append("latency \(connectMS) ms") }
        if totalMS > 0 { parts.append("total \(totalMS) ms") }
        if doubtful { parts.append("rechecking") }
        return parts.joined(separator: " · ")
    }
}
