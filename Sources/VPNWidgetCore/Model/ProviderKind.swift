import Foundation

/// The native client that owns a VPN profile, told from the Network Extension
/// provider that the system records for it.
public enum ProviderKind: String, Codable, CaseIterable, Hashable, Sendable {
    case forticlient
    case anyconnect
    case amneziawg
    case wireguard
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
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .forticlient: "FortiClient"
        case .anyconnect: "AnyConnect"
        case .amneziawg: "AmneziaWG"
        case .wireguard: "WireGuard"
        case .other: "Other"
        }
    }

    /// Bundle identifiers of the client's own application, tried in order when
    /// the system cannot finish a connection without the client's window.
    public var clientBundleIDs: [String] {
        switch self {
        case .forticlient: ["com.fortinet.FortiClient"]
        case .anyconnect: ["com.cisco.secureclient.gui", "com.cisco.anyconnect.gui"]
        case .amneziawg: ["org.amnezia.awg"]
        case .wireguard: ["com.wireguard.macos"]
        case .other: []
        }
    }

    /// Whether connecting normally needs the user: a SAML page or a password.
    public var signsInInteractively: Bool {
        switch self {
        case .forticlient, .anyconnect: true
        case .amneziawg, .wireguard, .other: false
        }
    }
}
