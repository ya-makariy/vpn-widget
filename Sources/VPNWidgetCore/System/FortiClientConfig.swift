import Foundation

/// What FortiClient knows about its own connections. FortiClient registers one
/// VPN profile with the system, named "VPN", and keeps its connections in its
/// own, world-readable configuration; the widget reads their names to tell the
/// user what to choose.
public enum FortiClientConfig {
    public static let path = "/Library/Application Support/Fortinet/FortiClient/conf/vpn.plist"

    /// The names of the connections, in FortiClient's order.
    public static func connectionNames(at path: String = FortiClientConfig.path) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [] }
        var names: [String] = []
        collectNames(in: plist, into: &names)
        return names
    }

    private static func collectNames(in value: Any, into names: inout [String]) {
        if let dict = value as? [String: Any] {
            if let name = dict["Name"] as? String, dict["Server"] != nil, !names.contains(name) {
                names.append(name)
            }
            for (_, v) in dict { collectNames(in: v, into: &names) }
        } else if let array = value as? [Any] {
            for v in array { collectNames(in: v, into: &names) }
        }
    }

    /// The hint for the row while FortiClient's window is up.
    public static func connectHint(names: [String] = connectionNames()) -> String {
        switch names.count {
        case 0: "Click Connect in FortiClient"
        case 1: "Click Connect in FortiClient (\(names[0]))"
        default: "In FortiClient choose \(names.joined(separator: " or ")) and click Connect"
        }
    }
}
