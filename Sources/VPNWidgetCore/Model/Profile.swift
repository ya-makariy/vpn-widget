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

    public init(
        id: String,
        displayName: String,
        providerKind: ProviderKind,
        checkURL: URL? = nil,
        insecureTLS: Bool = false,
        autoConnect: Bool = false,
        dnsDomains: [String] = [],
        dnsServers: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.checkURL = checkURL
        self.insecureTLS = insecureTLS
        self.autoConnect = autoConnect
        self.dnsDomains = dnsDomains
        self.dnsServers = dnsServers
    }

    /// A profile with defaults for a service the user just added.
    public init(adopting service: DiscoveredService) {
        self.init(id: service.id, displayName: service.name, providerKind: service.kind)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, providerKind, checkURL, insecureTLS, autoConnect, dnsDomains, dnsServers
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
