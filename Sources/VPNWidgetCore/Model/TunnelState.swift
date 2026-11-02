import Foundation

/// What a tunnel daemon is doing, as it writes it to its state file for the
/// widget to read. The file is world-readable; nothing secret goes in it.
public struct TunnelState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case starting
        case waitingForGateway
        case waitingForSignIn
        case connecting
        case connected
        case failed
        case stopped
    }

    public var phase: Phase
    /// When this phase began.
    public var since: Date
    /// When the link came up, while connected.
    public var connectedSince: Date?
    /// The page to sign in at, while waiting for SAML.
    public var signInURL: String?
    /// Changes when the user should be shown the page again: the first time,
    /// and after a drop. Quiet restarts of an unattended sign-in keep it.
    public var signInAttempt: Int
    public var interfaceName: String?
    public var dnsServers: [String]
    /// Why it failed, or what it is waiting for.
    public var message: String?
    /// What to trust to get past a certificate the system does not know.
    public var untrustedCertificate: String?
    public var pid: Int32
    public var updated: Date

    public init(phase: Phase, since: Date, connectedSince: Date? = nil, signInURL: String? = nil, signInAttempt: Int = 0, interfaceName: String? = nil, dnsServers: [String] = [], message: String? = nil, untrustedCertificate: String? = nil, pid: Int32 = 0, updated: Date = Date()) {
        self.phase = phase
        self.since = since
        self.connectedSince = connectedSince
        self.signInURL = signInURL
        self.signInAttempt = signInAttempt
        self.interfaceName = interfaceName
        self.dnsServers = dnsServers
        self.message = message
        self.untrustedCertificate = untrustedCertificate
        self.pid = pid
        self.updated = updated
    }

    /// The status the engine understands. A state whose daemon is gone counts
    /// as stopped, whatever the file says.
    public func rawStatus(daemonAlive: Bool) -> RawConnectionStatus {
        switch phase {
        case .connected: daemonAlive ? .connected : .disconnected
        case .starting, .waitingForGateway, .waitingForSignIn, .connecting: daemonAlive ? .connecting : .disconnected
        case .failed: .failed
        case .stopped: .disconnected
        }
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
