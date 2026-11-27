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
    /// The tunnel's own address, to find the interface again if it changes.
    public var address: String?
    public var dnsServers: [String]
    /// Why it failed, or what it is waiting for.
    public var message: String?
    /// What to trust to get past a certificate the system does not know.
    public var untrustedCertificate: String?
    /// The tunnel was asked to carry the default route (amneziawg:
    /// `AllowedIPs = 0.0.0.0/0`). Nil in files from before this was written.
    public var defaultRoute: Bool?
    /// Networks of this tunnel that another tunnel's route took, and the
    /// stand-in ranges they are reached by instead. Nil in files from before
    /// this was written.
    public var fakeNetworks: [FakeNetwork]?
    /// The daemon knows stand-in ranges, so the tunnel can give a shared
    /// network up to another. Nil from daemons before them.
    public var supportsStandIns: Bool?
    /// The helper build the daemon runs (TunnelFiles.helperBuild), to tell a
    /// daemon started before the helper was replaced. Nil from older daemons.
    public var helperBuild: String?
    public var pid: Int32
    public var updated: Date

    public init(phase: Phase, since: Date, connectedSince: Date? = nil, signInURL: String? = nil, signInAttempt: Int = 0, interfaceName: String? = nil, address: String? = nil, dnsServers: [String] = [], message: String? = nil, untrustedCertificate: String? = nil, defaultRoute: Bool? = nil, fakeNetworks: [FakeNetwork]? = nil, supportsStandIns: Bool? = nil, helperBuild: String? = nil, pid: Int32 = 0, updated: Date = Date()) {
        self.phase = phase
        self.since = since
        self.connectedSince = connectedSince
        self.signInURL = signInURL
        self.signInAttempt = signInAttempt
        self.interfaceName = interfaceName
        self.address = address
        self.dnsServers = dnsServers
        self.message = message
        self.untrustedCertificate = untrustedCertificate
        self.defaultRoute = defaultRoute
        self.fakeNetworks = fakeNetworks
        self.supportsStandIns = supportsStandIns
        self.helperBuild = helperBuild
        self.pid = pid
        self.updated = updated
    }

    /// A network another tunnel has, reached through a stand-in range.
    public struct FakeNetwork: Codable, Equatable, Sendable {
        public var real: String
        public var fake: String
        /// The interface whose route took the real network; empty when none
        /// does now and the range is kept from before.
        public var sharedWith: String

        public init(real: String, fake: String, sharedWith: String) {
            self.real = real
            self.fake = fake
            self.sharedWith = sharedWith
        }
    }

    /// The daemon runs an older helper than the one installed now: it picks
    /// the new one up when the tunnel reconnects.
    public func runsOlderHelper(than installed: String?) -> Bool {
        guard let installed else { return false }
        return helperBuild != installed
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
