import Foundation

/// Reading what `awg` and the routing table say about a running tunnel.
public enum WireGuardStatus {
    /// A session whose last handshake is older than this is not carrying
    /// traffic: WireGuard makes a new one every two minutes while packets
    /// flow, and gives the old keys up after three.
    public static let handshakeFreshFor: TimeInterval = 180

    public enum Link: Equatable, Sendable {
        /// No peer has completed a handshake yet.
        case waiting
        case up
        /// There was a handshake, too long ago.
        case stale
    }

    /// The newest handshake in `awg show <interface> latest-handshakes`: a
    /// line per peer, the public key, a tab, and the time in seconds since
    /// 1970, 0 for a peer that never completed one.
    public static func latestHandshake(in output: String) -> Date? {
        let times = output.split(separator: "\n").compactMap { line -> UInt64? in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, let last = fields.last else { return nil }
            return UInt64(last)
        }
        guard let newest = times.max(), newest > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }

    public static func link(latestHandshake: Date?, now: Date) -> Link {
        guard let latestHandshake else { return .waiting }
        return now.timeIntervalSince(latestHandshake) < handshakeFreshFor ? .up : .stale
    }

    /// The peers' addresses in `awg show <interface> endpoints`, after awg
    /// resolved their names: `key<TAB>192.0.2.1:51820`, `[2001:db8::1]:51820`
    /// or `(none)`.
    public static func endpoints(in output: String) -> [IPNetwork] {
        var out: [IPNetwork] = []
        for line in output.split(separator: "\n") {
            guard let field = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last,
                  let endpoint = WireGuardConf.endpoint(String(field)), let address = IPNetwork(endpoint.host)
            else { continue }
            if !out.contains(address) { out.append(address) }
        }
        return out
    }

    /// The default gateway in `netstat -nr -f inet` or `-f inet6`: the first
    /// `default` line whose gateway is an address rather than a link. An IPv6
    /// gateway may carry a scope, `fe80::1%en0`.
    public static func defaultGateway(inNetstat output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count >= 2, fields[0] == "default", !fields[1].hasPrefix("link#") else { continue }
            let parts = fields[1].split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2, let address = IPNetwork(String(parts[0])), !parts[0].contains("/") else { continue }
            if parts.count == 2 {
                guard (1...15).contains(parts[1].count), parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
                return "\(address.address)%\(parts[1])"
            }
            return address.address
        }
        return nil
    }

    /// The interface in `route -n get`'s answer.
    public static func routeInterface(inRouteGet output: String) -> String? {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ":", maxSplits: 1)
            if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "interface" {
                return fields[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

/// The argument lists of the commands that bring a tunnel's interface up and
/// down: what wg-quick runs on macOS, as arrays, never through a shell.
/// Everything in them is an interface name amneziawg-go reported or an address
/// rebuilt from its parsed bytes.
public enum WireGuardCommands {
    public static let ifconfig = "/sbin/ifconfig"
    public static let route = "/sbin/route"
    public static let netstat = "/usr/sbin/netstat"
    /// Where amneziawg-go listens for awg, per interface.
    public static let socketDirectory = "/var/run/amneziawg"

    public static func socketPath(interface: String) -> String { "\(socketDirectory)/\(interface).sock" }

    public static func setconf(interface: String, file: String) -> [String] { ["setconf", interface, file] }
    public static func show(interface: String, _ what: String) -> [String] { ["show", interface, what] }

    public static func addAddress(_ address: IPNetwork, interface: String) -> [String] {
        address.isIPv6
            ? [interface, "inet6", address.description, "alias"]
            : [interface, "inet", address.description, address.address, "alias"]
    }

    public static func setMTU(_ mtu: Int, interface: String) -> [String] { [interface, "mtu", String(mtu)] }
    public static func up(interface: String) -> [String] { [interface, "up"] }

    private static func family(_ network: IPNetwork) -> String { network.isIPv6 ? "-inet6" : "-inet" }

    public static func addRoute(_ network: IPNetwork, interface: String) -> [String] {
        ["-q", "-n", "add", family(network), network.description, "-interface", interface]
    }

    public static func getRoute(_ network: IPNetwork) -> [String] { ["-n", "get", family(network), network.description] }
    public static func deleteRoute(_ network: IPNetwork) -> [String] { ["-q", "-n", "delete", family(network), network.description] }

    /// A host route that keeps the tunnel's own packets to its peer outside
    /// the tunnel. With no gateway there is nowhere to send them: a blackhole
    /// instead of a loop, until a gateway appears.
    public static func addEndpointRoute(_ endpoint: IPNetwork, gateway: String?) -> [String] {
        if let gateway { return ["-q", "-n", "add", family(endpoint), endpoint.address, "-gateway", gateway] }
        return ["-q", "-n", "add", family(endpoint), endpoint.address, endpoint.isIPv6 ? "::1" : "127.0.0.1", "-blackhole"]
    }

    public static func deleteEndpointRoute(_ endpoint: IPNetwork) -> [String] { ["-q", "-n", "delete", family(endpoint), endpoint.address] }

    public static func routingTable(ipv6: Bool) -> [String] { ["-nr", "-f", ipv6 ? "inet6" : "inet"] }
}

/// amneziawg-go says little: it logs `ERROR: (utun6) …` lines, and the state
/// of the link is asked of awg instead.
public enum AmneziaWGOutput {
    public static func parse(_ line: String) -> ToolEvent? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ERROR:") else { return nil }
        return .error(text.dropFirst("ERROR:".count).trimmingCharacters(in: .whitespaces))
    }
}
