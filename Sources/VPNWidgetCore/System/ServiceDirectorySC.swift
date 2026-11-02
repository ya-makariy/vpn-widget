import Foundation
import SystemConfiguration

/// Lists VPN profiles through SystemConfiguration. Profiles made by Network
/// Extension clients appear here with the provider in their configuration.
public struct ServiceDirectorySC: ServiceDirectory {
    public init() {}

    public func listVPNServices() async throws -> [DiscoveredService] {
        guard let prefs = SCPreferencesCreate(nil, "VPN Widget" as CFString, nil) else {
            throw ActionError("cannot read network preferences: \(scErrorText())")
        }
        guard let all = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return [] }
        var out: [DiscoveredService] = []
        for service in all {
            guard let iface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(iface) as String?,
                  type == "VPN",
                  let id = SCNetworkServiceGetServiceID(service) as String?
            else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? id
            let config = SCNetworkInterfaceGetConfiguration(iface) as? [String: Any]
            out.append(DiscoveredService(
                id: id,
                name: name,
                enabled: SCNetworkServiceGetEnabled(service),
                providerBundleID: config?["NEProviderBundleIdentifier"] as? String
            ))
        }
        return out
    }
}

func scErrorText() -> String {
    String(cString: SCErrorString(SCError()))
}
