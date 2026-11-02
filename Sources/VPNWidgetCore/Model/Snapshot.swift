import Foundation

/// One VPN at one moment. `checked` is false when the tunnel is down or has no
/// check URL, as a check could then only fail or go out by another route.
public struct ProfileState: Equatable, Identifiable, Sendable {
    public var profile: VPNProfile
    public var state: ConnectionState
    public var checked: Bool
    public var result: CheckResult
    public var traffic: Traffic?
    /// When the tunnel came up, from the system's last status change.
    public var connectedSince: Date?
    /// When the current connecting or disconnecting began, as far as polling saw.
    public var transitionSince: Date?
    /// The client's own window is where the connection is being finished; the
    /// text says what to do there. Nil when the system is doing it.
    public var clientHint: String?
    public var interfaceName: String?
    /// The DNS servers and search domains the tunnel pushed, for the split-DNS editor.
    public var dnsServers: [String]
    public var dnsSearchDomains: [String]
    /// The tunnel carries the default route.
    public var isPrimaryInterface: Bool
    /// The tunnel's DNS servers answer every query, not only its domains.
    public var takesOverDNS: Bool
    /// Why the last Connect, Disconnect or Reconnect could not be queued.
    public var lastActionError: String?
    /// Why the tunnel failed, from its daemon.
    public var failure: String?
    /// The page to sign in at, while an own tunnel waits for SAML; the attempt
    /// number changes when the user should be shown the page again.
    public var signInURL: URL?
    public var signInAttempt: Int

    public init(
        profile: VPNProfile,
        state: ConnectionState,
        checked: Bool = false,
        result: CheckResult = CheckResult(),
        traffic: Traffic? = nil,
        connectedSince: Date? = nil,
        transitionSince: Date? = nil,
        clientHint: String? = nil,
        interfaceName: String? = nil,
        dnsServers: [String] = [],
        dnsSearchDomains: [String] = [],
        isPrimaryInterface: Bool = false,
        takesOverDNS: Bool = false,
        lastActionError: String? = nil,
        failure: String? = nil,
        signInURL: URL? = nil,
        signInAttempt: Int = 0
    ) {
        self.profile = profile
        self.state = state
        self.checked = checked
        self.result = result
        self.traffic = traffic
        self.connectedSince = connectedSince
        self.transitionSince = transitionSince
        self.clientHint = clientHint
        self.interfaceName = interfaceName
        self.dnsServers = dnsServers
        self.dnsSearchDomains = dnsSearchDomains
        self.isPrimaryInterface = isPrimaryInterface
        self.takesOverDNS = takesOverDNS
        self.lastActionError = lastActionError
        self.failure = failure
        self.signInURL = signInURL
        self.signInAttempt = signInAttempt
    }

    public var id: String { profile.id }

    /// The state in words, with the check when it failed.
    public var statusText: String {
        var text = state.text
        if checked, result.failed { text += ", service not answering" }
        return text
    }

    /// The line about the tunnel itself: traffic and uptime. Empty when down.
    public func linkLine(now: Date) -> String {
        var parts: [String] = []
        if let traffic { parts.append(traffic.description) }
        if let connectedSince { parts.append("up " + formatUptime(now.timeIntervalSince(connectedSince))) }
        return parts.joined(separator: " · ")
    }
}

/// Everything the menu shows.
public struct Snapshot: Equatable, Sendable {
    public var profiles: [ProfileState]
    public var at: Date

    public init(profiles: [ProfileState], at: Date) {
        self.profiles = profiles
        self.at = at
    }

    /// Whether some check has just started failing, so that the next poll
    /// should come soon.
    public var doubtful: Bool {
        profiles.contains { $0.checked && $0.result.doubtful }
    }

    /// Sums up the VPNs for the icon.
    public var level: IconLevel {
        var connected = 0
        var progress = false
        for p in profiles {
            switch p.state {
            case .connected:
                if p.checked, p.result.failed { return .problem }
                connected += 1
            case .connecting, .disconnecting:
                progress = true
            case .invalid, .failed:
                return .problem
            case .disconnected, .notFound:
                break
            }
        }
        if progress { return .progress }
        switch connected {
        case 0: return .off
        case profiles.count: return .ok
        default: return .partial
        }
    }
}

public enum IconLevel: Sendable, Equatable {
    /// No VPN is connected, and nothing is wrong.
    case off
    /// All VPNs are connected and reach their services.
    case ok
    /// Some VPNs are stopped, as asked for.
    case partial
    /// Some VPN is on its way up or down, and nothing is wrong.
    case progress
    /// Something needs attention. The icon blinks.
    case problem
}
