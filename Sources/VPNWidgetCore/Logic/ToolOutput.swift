import Foundation

/// What the tunnel tools say on their output, reduced to the events the daemon
/// acts on. Everything else is just logged.
public enum ToolEvent: Equatable, Sendable {
    /// SAML: the page to sign in at.
    case signInURL(String)
    /// SAML: nobody signed in before the tool gave up listening.
    case signInTimedOut
    /// The gateway handed out addresses; name servers when it sent any.
    case addresses(ip: String, dns: [String])
    /// The link is up, on this interface and with this address when known.
    case up(interface: String?, address: String?)
    /// The session ended on the far side or the link went down.
    case down(String)
    /// Authentication was refused: retrying blindly is pointless.
    case authenticationFailed(String)
    /// The gateway's certificate is not trusted; the value is what the tool
    /// wants to be told to trust it (openconnect's pin, openfortivpn's digest).
    case untrustedCertificate(String)
    /// Something else went wrong; the text is the tool's own.
    case error(String)
}

public enum OpenFortiVPNOutput {
    public static func parse(_ line: String) -> ToolEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "Authenticate at '") {
            let rest = text[range.upperBound...]
            if let end = rest.firstIndex(of: "'") { return .signInURL(String(rest[..<end])) }
        }
        if text.contains("Timeout listening for incoming HTTP connection") { return .signInTimedOut }
        if let range = text.range(of: "Got addresses: ") {
            let rest = String(text[range.upperBound...])
            let ips = addresses(in: rest)
            guard let ip = ips.first else { return nil }
            return .addresses(ip: ip, dns: Array(ips.dropFirst()))
        }
        if text.contains("Tunnel is up and running") { return .up(interface: nil, address: nil) }
        if let range = text.range(of: "Interface "), text.contains(" is UP") {
            let rest = text[range.upperBound...]
            if let end = rest.firstIndex(of: " ") { return .up(interface: String(rest[..<end]), address: nil) }
        }
        if text.contains("Logged out") || text.contains("Remote gateway has closed the connection") || text.contains("pppd: The link was terminated") {
            return .down(text.replacingOccurrences(of: "INFO:   ", with: ""))
        }
        if text.contains("Could not authenticate") || text.contains("Finally failed to retrieve SAML authentication token") || text.contains("Login failed") {
            return .authenticationFailed(text)
        }
        if let range = text.range(of: "--trusted-cert ") {
            let digest = text[range.upperBound...].prefix { $0.isHexDigit }
            if digest.count >= 32 { return .untrustedCertificate(String(digest)) }
        }
        if text.contains("certificate validation failed") || text.contains("certificate digest is not in the local whitelist") {
            return .error(text.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces))
        }
        if text.hasPrefix("ERROR:") {
            return .error(text.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func addresses(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch.isNumber || ch == "." || ch == ":" || ch.isHexDigit && !ch.isNumber && current.contains(":") {
                current.append(ch)
            } else {
                if ResolverFiles.isServer(current) { out.append(current) }
                current = ""
            }
        }
        if ResolverFiles.isServer(current) { out.append(current) }
        return out
    }
}

public enum OpenConnectOutput {
    public static func parse(_ line: String) -> ToolEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Older versions: "Connected utun6 as 172.16.0.5, using SSL"; 9.x: "Configured as 172.16.0.5, with SSL connected".
        if text.hasPrefix("Connected "), let asRange = text.range(of: " as ") {
            let device = String(text[text.index(text.startIndex, offsetBy: "Connected ".count)..<asRange.lowerBound])
            if device.hasPrefix("utun") || device.hasPrefix("tun") {
                let address = text[asRange.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
                return .up(interface: device, address: String(address))
            }
        }
        if text.hasPrefix("Configured as ") {
            let address = text.dropFirst("Configured as ".count).prefix { !$0.isWhitespace && $0 != "," }
            return .up(interface: nil, address: ResolverFiles.isServer(String(address)) ? String(address) : nil)
        }
        if text.contains("Login failed") || text.contains("Failed to obtain WebVPN cookie") || text.contains("Authentication failed") {
            return .authenticationFailed(text)
        }
        if let range = text.range(of: "--servercert ") {
            let pin = text[range.upperBound...].prefix { !$0.isWhitespace }
            if pin.hasPrefix("pin-sha256:") { return .untrustedCertificate(String(pin)) }
        }
        if text.contains("Failed to connect to host") || text.contains("Failed to open HTTPS connection") || text.contains("SSL connection failure") {
            return .error(text)
        }
        if text.contains("Logout successful") || text.contains("Connection terminated") || text.contains("SSL read error") || text.contains("Reconnect failed") {
            return .down(text)
        }
        return nil
    }
}

/// How long to wait before trying again after a drop: from 5 seconds to 5
/// minutes, doubling, reset once a session has lasted a minute.
public struct Backoff: Equatable, Sendable {
    public var minimum: TimeInterval = 5
    public var maximum: TimeInterval = 300
    public var resetAfterSession: TimeInterval = 60
    private var current: TimeInterval?

    public init() {}

    /// The wait after a failure, given how long the session that just ended lasted.
    public mutating func next(sessionLasted: TimeInterval) -> TimeInterval {
        if sessionLasted >= resetAfterSession { current = nil }
        let wait = current ?? minimum
        current = min(wait * 2, maximum)
        return wait
    }

    public mutating func reset() { current = nil }
}
