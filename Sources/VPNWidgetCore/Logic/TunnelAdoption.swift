import Foundation

/// Showing an own tunnel in the panel, and mending one that lost its config.
/// The widget's settings hold only shown profiles, so a tunnel that is shown
/// again gets its config back from the copy its helper installed.
public enum TunnelAdoption {
    /// The installed profile of a tunnel, by tunnel name: nil when the copy
    /// is missing or unreadable.
    public typealias Installed = (String) -> VPNProfile?

    /// The profile for a service the user just turned on. Another app's
    /// profile starts from defaults; an own tunnel is taken as installed, and
    /// is nil when that copy cannot be read: without its config it would be a
    /// plain profile under a tunnel's id.
    public static func profile(adopting service: DiscoveredService, installed: Installed) -> VPNProfile? {
        guard let name = TunnelConfig.name(fromProfileID: service.id) else { return VPNProfile(adopting: service) }
        return usable(installed(name), id: service.id)
    }

    /// The profiles with every own tunnel that lost its config given it back
    /// from the installed copy. What was set here since stays: the name, the
    /// check and split DNS when not empty, and switches that are on. Other
    /// apps' profiles, tunnels that have their config, and tunnels with no
    /// installed copy are left as they are.
    public static func repaired(_ profiles: [VPNProfile], installed: Installed) -> [VPNProfile] {
        profiles.map { stored in
            guard stored.tunnel == nil, let name = TunnelConfig.name(fromProfileID: stored.id),
                  var profile = usable(installed(name), id: stored.id)
            else { return stored }
            profile.displayName = stored.displayName
            if let url = stored.checkURL { profile.checkURL = url }
            if stored.insecureTLS { profile.insecureTLS = true }
            if stored.autoConnect { profile.autoConnect = true }
            if !stored.dnsDomains.isEmpty { profile.dnsDomains = stored.dnsDomains }
            if !stored.dnsServers.isEmpty { profile.dnsServers = stored.dnsServers }
            return profile
        }
    }

    /// An installed copy counts only when it is this tunnel's and has a config.
    private static func usable(_ profile: VPNProfile?, id: String) -> VPNProfile? {
        guard let profile, profile.id == id, profile.tunnel != nil else { return nil }
        return profile
    }
}
