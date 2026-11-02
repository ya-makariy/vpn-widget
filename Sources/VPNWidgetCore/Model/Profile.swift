import Foundation

/// A VPN profile that the system knows about: created by one of the native
/// clients, listed through SystemConfiguration.
public struct DiscoveredService: Hashable, Identifiable, Sendable {
    /// The SystemConfiguration service ID, a UUID string.
    public var id: String
    /// The name the client gave the profile.
    public var name: String
    public var enabled: Bool
    public var providerBundleID: String?

    public init(id: String, name: String, enabled: Bool, providerBundleID: String?) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.providerBundleID = providerBundleID
    }

    public var kind: ProviderKind { ProviderKind(bundleID: providerBundleID) }
}

/// One VPN the widget shows: a system profile plus what the user said about it.
/// The order of profiles in the store is the order in the panel.
public struct VPNProfile: Codable, Hashable, Identifiable, Sendable {
    /// The SystemConfiguration service ID of the profile.
    public var id: String
    public var displayName: String
    public var providerKind: ProviderKind
    /// The service behind the tunnel to check. Nothing is checked when nil.
    public var checkURL: URL?
    /// Skips certificate verification for the check: internal services often
    /// use a private CA, and the check is about reach, not trust.
    public var insecureTLS: Bool
    /// Connect when the widget starts.
    public var autoConnect: Bool
    /// Domains that should resolve through this tunnel's DNS servers.
    public var dnsDomains: [String]
    public var dnsServers: [String]
    /// Set for tunnels the widget runs itself; nil for other apps' profiles.
    public var tunnel: TunnelConfig?

    public init(
        id: String,
        displayName: String,
        providerKind: ProviderKind,
        checkURL: URL? = nil,
        insecureTLS: Bool = false,
        autoConnect: Bool = false,
        dnsDomains: [String] = [],
        dnsServers: [String] = [],
        tunnel: TunnelConfig? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.checkURL = checkURL
        self.insecureTLS = insecureTLS
        self.autoConnect = autoConnect
        self.dnsDomains = dnsDomains
        self.dnsServers = dnsServers
        self.tunnel = tunnel
    }

    /// A profile for a tunnel the widget runs itself.
    public init(tunnel: TunnelConfig, displayName: String) {
        self.init(id: TunnelConfig.profileID(name: tunnel.name), displayName: displayName, providerKind: tunnel.kind.providerKind, tunnel: tunnel)
    }

    public var isOwnTunnel: Bool { tunnel != nil }

    /// A profile with defaults for a service the user just added.
    public init(adopting service: DiscoveredService) {
        self.init(id: service.id, displayName: service.name, providerKind: service.kind)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, providerKind, checkURL, insecureTLS, autoConnect, dnsDomains, dnsServers, tunnel
    }

    /// Missing keys take their defaults, so that a file from an older version loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? id
        providerKind = try c.decodeIfPresent(ProviderKind.self, forKey: .providerKind) ?? .other
        checkURL = try c.decodeIfPresent(URL.self, forKey: .checkURL)
        insecureTLS = try c.decodeIfPresent(Bool.self, forKey: .insecureTLS) ?? false
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? false
        dnsDomains = try c.decodeIfPresent([String].self, forKey: .dnsDomains) ?? []
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        tunnel = try c.decodeIfPresent(TunnelConfig.self, forKey: .tunnel)
    }
}

/// A tunnel the widget runs itself, through a CLI tool under launchd.
public struct TunnelConfig: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case openfortivpn
        case openconnect

        public var providerKind: ProviderKind {
            switch self {
            case .openfortivpn: .openfortivpn
            case .openconnect: .openconnect
            }
        }

        /// Stands in for the Network Extension provider id in discovery.
        public var providerBundleID: String { "com.ya-makariy.vpn-widget.tunnel.\(rawValue)" }

        public var displayName: String {
            switch self {
            case .openfortivpn: "FortiGate SSL VPN (openfortivpn)"
            case .openconnect: "AnyConnect (openconnect)"
            }
        }
    }

    /// A short name: letters, digits and dashes. It names the daemon, its
    /// files and the profile.
    public var name: String
    public var kind: Kind
    public var host: String
    public var port: Int
    /// openfortivpn: the authentication realm. openconnect: the auth group.
    public var realm: String?
    /// openfortivpn: sign in through SAML in the browser.
    public var saml: Bool
    public var username: String?
    /// A password is stored for this tunnel, in a root-only file.
    public var hasSecret: Bool
    /// openfortivpn: `--trusted-cert` digest. openconnect: `--servercert` pin.
    public var trustedCert: String?
    /// openconnect: `--protocol`, anyconnect when nil.
    public var protocolName: String?
    public var extraArguments: [String]

    public init(name: String, kind: Kind, host: String, port: Int, realm: String? = nil, saml: Bool = false, username: String? = nil, hasSecret: Bool = false, trustedCert: String? = nil, protocolName: String? = nil, extraArguments: [String] = []) {
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.realm = realm
        self.saml = saml
        self.username = username
        self.hasSecret = hasSecret
        self.trustedCert = trustedCert
        self.protocolName = protocolName
        self.extraArguments = extraArguments
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, host, port, realm, saml, username, hasSecret, trustedCert, protocolName, extraArguments
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 443
        realm = try c.decodeIfPresent(String.self, forKey: .realm)
        saml = try c.decodeIfPresent(Bool.self, forKey: .saml) ?? false
        username = try c.decodeIfPresent(String.self, forKey: .username)
        hasSecret = try c.decodeIfPresent(Bool.self, forKey: .hasSecret) ?? false
        trustedCert = try c.decodeIfPresent(String.self, forKey: .trustedCert)
        protocolName = try c.decodeIfPresent(String.self, forKey: .protocolName)
        extraArguments = try c.decodeIfPresent([String].self, forKey: .extraArguments) ?? []
    }

    public static let profileIDPrefix = "tunnel:"

    public static func profileID(name: String) -> String { profileIDPrefix + name }

    /// The tunnel name behind a profile id, or nil for other apps' profiles.
    public static func name(fromProfileID id: String) -> String? {
        id.hasPrefix(profileIDPrefix) ? String(id.dropFirst(profileIDPrefix.count)) : nil
    }

    /// Whether a name can be used in file names and a launchd label.
    public static func isValidName(_ name: String) -> Bool {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        return !name.isEmpty && name.count <= 40 && name.unicodeScalars.allSatisfy(allowed.contains)
            && !name.hasPrefix("-") && !name.hasSuffix("-")
    }

    /// A name from a display name: lowercase, dashes for the rest.
    public static func suggestName(from title: String) -> String {
        var out = ""
        var lastDash = true
        for ch in title.lowercased().unicodeScalars {
            if CharacterSet.lowercaseLetters.union(.decimalDigits).contains(ch) {
                out.unicodeScalars.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(40))
    }
}

/// Everything the widget persists.
public struct StoredConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var profiles: [VPNProfile]
    /// Domains whose `/etc/resolver` files the widget wrote, so that it can
    /// remove the ones no profile claims any more.
    public var managedResolverDomains: [String]

    public init(version: Int = StoredConfig.currentVersion, profiles: [VPNProfile] = [], managedResolverDomains: [String] = []) {
        self.version = version
        self.profiles = profiles
        self.managedResolverDomains = managedResolverDomains
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, managedResolverDomains }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? StoredConfig.currentVersion
        profiles = try c.decodeIfPresent([VPNProfile].self, forKey: .profiles) ?? []
        managedResolverDomains = try c.decodeIfPresent([String].self, forKey: .managedResolverDomains) ?? []
    }
}
