import Foundation

/// The native client that owns a VPN profile, told from the Network Extension
/// provider that the system records for it.
public enum ProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case forticlient
    case anyconnect
    case amneziawg
    case wireguard
    /// A tunnel the widget runs itself with openfortivpn (FortiGate SSL VPN).
    case openfortivpn
    /// A tunnel the widget runs itself with openconnect (AnyConnect protocol).
    case openconnect
    case other

    /// Classifies a provider by its `NEProviderBundleIdentifier`. Prefixes are
    /// matched so that a client renaming its extension target keeps working.
    public init(bundleID: String?) {
        guard let bundleID else {
            self = .other
            return
        }
        switch bundleID {
        case let id where id.hasPrefix("com.fortinet.forticlient"): self = .forticlient
        case let id where id.hasPrefix("com.cisco.anyconnect"): self = .anyconnect
        case let id where id.hasPrefix("org.amnezia.awg"): self = .amneziawg
        case let id where id.hasPrefix("com.wireguard.macos"): self = .wireguard
        case TunnelConfig.Kind.openfortivpn.providerBundleID: self = .openfortivpn
        case TunnelConfig.Kind.openconnect.providerBundleID: self = .openconnect
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .forticlient: "FortiClient"
        case .anyconnect: "AnyConnect"
        case .amneziawg: "AmneziaWG"
        case .wireguard: "WireGuard"
        case .openfortivpn: "openfortivpn"
        case .openconnect: "openconnect"
        case .other: "Other"
        }
    }

    /// Tunnels the widget runs itself, as opposed to profiles of other apps.
    public var isOwnTunnel: Bool {
        switch self {
        case .openfortivpn, .openconnect: true
        default: false
        }
    }

    /// Bundle identifiers of the client's own application, tried in order when
    /// the system cannot finish a connection without the client's window.
    public var clientBundleIDs: [String] {
        switch self {
        case .forticlient: ["com.fortinet.FortiClient"]
        case .anyconnect: ["com.cisco.anyconnect", "com.cisco.secureclient.gui", "com.cisco.anyconnect.gui"]
        case .amneziawg: ["org.amnezia.awg"]
        case .wireguard: ["com.wireguard.macos"]
        case .openfortivpn, .openconnect, .other: []
        }
    }

    /// Whether connecting normally needs the user: a SAML page or a password.
    public var signsInInteractively: Bool {
        switch self {
        case .forticlient, .anyconnect, .openfortivpn: true
        case .amneziawg, .wireguard, .openconnect, .other: false
        }
    }
}
