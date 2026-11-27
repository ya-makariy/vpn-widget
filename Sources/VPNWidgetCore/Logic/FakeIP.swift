import Foundation

/// Stand-in addresses for networks two tunnels both route (issue #13).
///
/// The tunnel that finds part of its network routed by another tunnel gets
/// that part under a range of the documentation networks, with the same
/// prefix length, so that `10.20.0.20` behind it is reached as, say,
/// `192.0.2.20`. Its
/// split-DNS answers are rewritten into the range, pf hands TCP connections
/// to the range to the tunnel's daemon, and the daemon dials the real address
/// from a socket bound to its own interface, over an interface-scoped route
/// that leaves the other tunnel's route alone.
///
/// Everything here is pure: reading the routing table, finding overlaps,
/// handing out ranges, translating addresses, rewriting DNS answers, the pf
/// rules and the pf lookup's struct. The daemon does the rest.
public enum FakeIP {
    /// The documentation networks (RFC 5737, TEST-NET-1 to 3): reserved for
    /// examples, routed nowhere. Not `198.18.0.0/15`: that is where Clash,
    /// sing-box and routers running them hand out their own fake IPs, and
    /// taking connections to it breaks every site they proxy.
    public static let pools = [
        IPNetwork(bytes: [192, 0, 2, 0], prefix: 24),
        IPNetwork(bytes: [198, 51, 100, 0], prefix: 24),
        IPNetwork(bytes: [203, 0, 113, 0], prefix: 24),
    ]
    /// The widest network that gets a stand-in: a whole pool.
    public static let widestPrefix = 24
    /// Our networks wider than this are not looked into: the default route,
    /// its halves and the like carry everything, not a network.
    static let narrowestOwnPrefix = 8

    // MARK: The routing table

    /// One line of `netstat -nr -f inet`.
    public struct Route: Equatable, Sendable {
        public var destination: IPNetwork
        public var gateway: String
        public var flags: String
        public var interface: String

        public init(destination: IPNetwork, gateway: String, flags: String, interface: String) {
            self.destination = destination
            self.gateway = gateway
            self.flags = flags
            self.interface = interface
        }

        /// Bound to its interface (`-ifscope`): used only by sockets bound to
        /// it, so it takes nothing from anyone.
        public var isScoped: Bool { flags.contains("I") }

        /// A point-to-point interface's own address (`192.0.2.9 192.0.2.9 UH`):
        /// that tunnel's end of the link, nobody's network.
        public var isOwnAddress: Bool {
            flags.contains("H") && destination.prefix == 32 && gateway == destination.address
        }
    }

    /// The IPv4 routes in `netstat -nr -f inet`. netstat leaves off trailing
    /// zero octets and prints a prefix only when it is not the classful one:
    /// `192.168.77` is `192.168.77.0/24`, `172.16` is `172.16.0.0/16`,
    /// `10.100.102/24` gives its prefix, a host route (`H`) is a full address.
    public static func routes(inNetstat output: String) -> [Route] {
        var out: [Route] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, let first = fields[0].first, first.isNumber else { continue }
            let flags = String(fields[2])
            guard let destination = destination(String(fields[0]), host: flags.contains("H")) else { continue }
            out.append(Route(destination: destination, gateway: String(fields[1]), flags: flags, interface: String(fields[3])))
        }
        return out
    }

    static func destination(_ text: String, host: Bool) -> IPNetwork? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(octets.count) else { return nil }
        var bytes: [UInt8] = []
        for octet in octets {
            guard (1...3).contains(octet.count), octet.allSatisfy(\.isNumber), let value = UInt8(octet) else { return nil }
            bytes.append(value)
        }
        let given = bytes.count
        bytes += Array(repeating: 0, count: 4 - given)
        let prefix: Int
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...32).contains(p) else { return nil }
            prefix = p
        } else if host {
            prefix = 32
        } else {
            // No prefix printed: the classful mask (netstat adds `/n` only
            // when the mask is another), trailing zero octets left off.
            let classful = bytes[0] < 128 ? 8 : bytes[0] < 192 ? 16 : bytes[0] < 224 ? 24 : 32
            prefix = max(classful, given * 8)
        }
        return IPNetwork(bytes: bytes, prefix: prefix).network
    }

    /// Interfaces that belong to a VPN: utun (WireGuard, openconnect, the
    /// system's clients), ppp (openfortivpn), ipsec, tun/tap.
    public static func isTunnelInterface(_ name: String) -> Bool {
        ["utun", "ppp", "ipsec", "tun", "tap"].contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy(\.isNumber) && name.count > $0.count }
    }

    // MARK: Overlaps

    /// A part of one of our networks that the main table sends to another
    /// tunnel's interface.
    public struct Overlap: Hashable, Sendable {
        public var network: IPNetwork
        public var interface: String

        public init(network: IPNetwork, interface: String) {
            self.network = network
            self.interface = interface
        }
    }

    /// The parts of `ours` that another tunnel's interface has in the main
    /// table, the same network or a narrower one inside it: those win over
    /// ours, by being first or by being more specific. A wider route of
    /// another tunnel loses to ours and is not an overlap. Scoped routes take
    /// nothing; neither do routes through a physical interface (a peer's or a
    /// DNS server's host route by the gateway is there on purpose). The
    /// default route and other very wide ones of ours are not looked into. A
    /// narrower overlap inside a wider one is left out.
    public static func overlaps(of ours: [IPNetwork], on interface: String, in table: [Route]) -> [Overlap] {
        var found: [Overlap] = []
        for network in ours where !network.isIPv6 && network.prefix >= narrowestOwnPrefix {
            for route in table where !route.isScoped && !route.isOwnAddress && route.interface != interface && isTunnelInterface(route.interface) {
                let other = route.destination
                guard other.prefix >= network.prefix, network.contains(other) else { continue }
                found.append(Overlap(network: other.network, interface: route.interface))
            }
        }
        var minimal: [Overlap] = []
        for o in found where !found.contains(where: { $0 != o && $0.network.prefix < o.network.prefix && $0.network.contains(o.network) }) {
            if !minimal.contains(where: { $0.network == o.network }) { minimal.append(o) }
        }
        return minimal.sorted { $0.network.v4 < $1.network.v4 }
    }

    // MARK: Ranges

    /// One network and its stand-in.
    public struct Mapping: Codable, Hashable, Sendable {
        /// The tunnel the stand-in belongs to.
        public var tunnel: String
        public var real: String
        public var fake: String

        public init(tunnel: String, real: IPNetwork, fake: IPNetwork) {
            self.tunnel = tunnel
            self.real = real.description
            self.fake = fake.description
        }

        public var realNetwork: IPNetwork? { IPNetwork(real) }
        public var fakeNetwork: IPNetwork? { IPNetwork(fake) }

        /// The stand-in of an address in the real network, nil outside it.
        public func fake(for address: IPNetwork) -> IPNetwork? {
            guard let real = realNetwork, let fake = fakeNetwork, real.contains(address) else { return nil }
            return FakeIP.translate(address, from: real, to: fake)
        }

        /// The real address behind a stand-in, nil outside the range.
        public func real(for address: IPNetwork) -> IPNetwork? {
            guard let real = realNetwork, let fake = fakeNetwork, fake.contains(address) else { return nil }
            return FakeIP.translate(address, from: fake, to: real)
        }
    }

    /// The same host part under another network of the same prefix.
    public static func translate(_ address: IPNetwork, from: IPNetwork, to: IPNetwork) -> IPNetwork {
        let hostMask: UInt32 = from.prefix >= 32 ? 0 : UInt32.max >> UInt32(from.prefix)
        return IPNetwork(v4: (to.network.v4 & ~hostMask) | (address.v4 & hostMask), prefix: 32)
    }

    /// The first free block of `real`'s size in the pools, nil when they
    /// have none or the network is too wide. `taken` are the stand-ins already
    /// given out, and anything else in the pools to keep clear of.
    public static func allocate(for real: IPNetwork, taken: [IPNetwork]) -> IPNetwork? {
        guard !real.isIPv6, real.prefix >= widestPrefix else { return nil }
        let size = UInt64(1) << UInt64(32 - real.prefix)
        for pool in pools {
            let start = UInt64(pool.network.v4)
            let end = start + (UInt64(1) << UInt64(32 - pool.prefix))
            var candidate = start
            while candidate < end {
                let block = IPNetwork(v4: UInt32(candidate), prefix: real.prefix)
                if let clash = taken.first(where: { $0.overlaps(block) }) {
                    // Jump past the clash, to the next boundary of our size.
                    let past = UInt64(clash.network.v4) + (UInt64(1) << UInt64(32 - clash.prefix))
                    candidate = max(candidate + size, (past + size - 1) / size * size)
                    continue
                }
                return block
            }
        }
        return nil
    }

    /// Whether an address is in one of the pools.
    public static func inPools(_ network: IPNetwork) -> Bool {
        pools.contains { $0.overlaps(network) }
    }

    /// The stand-ins of all tunnels, kept across restarts so that addresses
    /// do not move under DNS caches and bookmarks, and which tunnel the user
    /// wants to hold each shared network. One file under the config directory,
    /// readable by the widget, written by root only; each writer takes a lock.
    public struct Table: Codable, Equatable, Sendable {
        public var mappings: [Mapping]
        /// A shared network (`10.20.0.0/24`) → the tunnel that holds its
        /// real addresses. The others reach it through their stand-ins.
        public var owners: [String: String]

        public init(mappings: [Mapping] = [], owners: [String: String] = [:]) {
            self.mappings = mappings
            self.owners = owners
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mappings = try c.decodeIfPresent([Mapping].self, forKey: .mappings) ?? []
            owners = try c.decodeIfPresent([String: String].self, forKey: .owners) ?? [:]
        }

        public func owner(of network: IPNetwork) -> String? { owners[network.network.description] }

        public mutating func setOwner(_ tunnel: String?, of network: IPNetwork) {
            owners[network.network.description] = tunnel
        }

        public func mapping(tunnel: String, real: IPNetwork) -> Mapping? {
            mappings.first { $0.tunnel == tunnel && $0.real == real.network.description }
        }

        /// The stand-in for a network of a tunnel: the one it had, or a new one.
        public mutating func assign(tunnel: String, real: IPNetwork, avoid: [IPNetwork] = []) -> Mapping? {
            // Ranges from outside the pools (an older pool) are given up, never reused.
            mappings.removeAll { !($0.fakeNetwork.map(FakeIP.inPools) ?? false) }
            if let known = mapping(tunnel: tunnel, real: real) { return known }
            let taken = mappings.compactMap(\.fakeNetwork) + avoid
            guard let fake = FakeIP.allocate(for: real.network, taken: taken) else { return nil }
            let mapping = Mapping(tunnel: tunnel, real: real.network, fake: fake)
            mappings.append(mapping)
            return mapping
        }

        /// Forgets a removed tunnel's stand-ins and choices.
        public mutating func remove(tunnel: String) {
            mappings.removeAll { $0.tunnel == tunnel }
            owners = owners.filter { $0.value != tunnel }
        }
    }

    // MARK: Who holds a shared network

    /// What a tunnel's daemon does to the main table for its networks.
    public enum RouteAction: Equatable, Sendable {
        /// Nobody routes the network: ours to add.
        case add(IPNetwork)
        /// The user chose this tunnel for a network another tunnel holds.
        case take(IPNetwork, from: String)
    }

    /// For each of our networks: added when nobody has it, taken from another
    /// tunnel's interface when the user chose us for it, left alone when we
    /// have it or another tunnel does and we were not chosen (the chosen one
    /// takes it itself). Routes through a physical interface are not taken.
    public static func routeActions(wanted: [IPNetwork], me: String, interface: String, table: [Route], owners: [String: String]) -> [RouteAction] {
        var actions: [RouteAction] = []
        for network in wanted where !network.isIPv6 && network.prefix >= narrowestOwnPrefix {
            let net = network.network
            let main = table.first { !$0.isScoped && $0.destination == net }
            guard let main else {
                actions.append(.add(net))
                continue
            }
            guard main.interface != interface else { continue }
            if owners[net.description] == me, isTunnelInterface(main.interface) {
                actions.append(.take(net, from: main.interface))
            }
        }
        return actions
    }

    /// A tunnel's networks other than through the config: the routes its tool
    /// put on its interface, less its own address and anything too wide.
    public static func networks(on interface: String, in table: [Route], ownAddress: String?) -> [IPNetwork] {
        table.filter { route in
            !route.isScoped && route.interface == interface && route.destination.prefix >= narrowestOwnPrefix
                && !(route.destination.prefix == 32 && route.destination.address == ownAddress)
        }.map(\.destination)
    }

    /// A network two or more own tunnels want, as the settings show it.
    public struct SharedNetwork: Equatable, Identifiable, Sendable {
        public struct Member: Equatable, Sendable {
            public var tunnel: String
            /// Its stand-in range, when it has one.
            public var fake: String?
            /// Its daemon knows stand-ins: it may give the network up.
            public var canShare: Bool
        }

        public var network: String
        /// The tunnel whose interface has the real network now; nil when it is
        /// not one of ours (a system VPN client's).
        public var holder: String?
        /// The tunnel the user chose; nil when none was chosen.
        public var chosen: String?
        public var members: [Member]
        public var id: String { network }
    }

    /// The shared networks, from the tunnels' state files and the table: a
    /// network is shared when a connected tunnel reaches it through a stand-in
    /// because another interface has it. Its members are that holder (when it
    /// is one of ours) and every tunnel with a stand-in for it.
    public static func sharedNetworks(states: [String: TunnelState], owners: [String: String]) -> [SharedNetwork] {
        let up = states.filter { $0.value.phase == .connected }
        var byInterface: [String: String] = [:]
        for (name, state) in up { if let i = state.interfaceName { byInterface[i] = name } }
        var holders: [String: String?] = [:]
        for state in up.values {
            for entry in state.fakeNetworks ?? [] where !entry.sharedWith.isEmpty {
                holders[entry.real] = byInterface[entry.sharedWith] ?? holders[entry.real] ?? nil
            }
        }
        return holders.keys.sorted().map { network in
            let holder = holders[network] ?? nil
            var names = Set(up.filter { ($0.value.fakeNetworks ?? []).contains { $0.real == network } }.map(\.key))
            if let holder { names.insert(holder) }
            let members = names.sorted().map { name in
                SharedNetwork.Member(
                    tunnel: name,
                    fake: up[name]?.fakeNetworks?.first { $0.real == network }?.fake,
                    canShare: up[name]?.supportsStandIns ?? false
                )
            }
            return SharedNetwork(network: network, holder: holder, chosen: owners[network], members: members)
        }
    }

    // MARK: pf

    /// The tunnel's own anchor, under the `com.apple/*` anchors that the
    /// system's `/etc/pf.conf` evaluates, so that file is never edited.
    public static func anchor(tunnel name: String) -> String {
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        return "com.apple/vpn-widget." + (plain ? name : name.utf8.map { String(format: "%02x", $0) }.joined())
    }

    /// The anchor's rules: TCP to a stand-in range is sent to `lo0` and,
    /// coming in there, redirected to the daemon's listener, which asks pf
    /// where it was going (`NatLook`). Translation rules first, as pf wants.
    /// TCP only: pf answers `DIOCNATLOOK` for redirected TCP connections, and
    /// for UDP datagrams finds no state (ENOENT); ICMP is not taken either.
    public static func pfRules(fakes: [IPNetwork], port: UInt16) -> String {
        let v4 = fakes.filter { !$0.isIPv6 }.map(\.network)
        var lines: [String] = []
        for fake in v4 {
            lines.append("rdr pass on lo0 inet proto tcp from any to \(fake) -> 127.0.0.1 port \(port)")
        }
        for fake in v4 {
            lines.append("pass out quick route-to lo0 inet proto tcp from any to \(fake) keep state")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The scoped route that lets a socket bound to the tunnel's interface
    /// reach the real network while another interface has it in the main
    /// table. `-ifscope` comes before the destination.
    public static func addScopedRoute(_ network: IPNetwork, interface: String) -> [String] {
        ["-q", "-n", "add", "-net", "-ifscope", interface, network.network.description, "-interface", interface]
    }

    public static func deleteScopedRoute(_ network: IPNetwork, interface: String) -> [String] {
        ["-q", "-n", "delete", "-net", "-ifscope", interface, network.network.description, "-interface", interface]
    }
}

// MARK: - pf's lookup of a redirected connection

/// `struct pfioc_natlook` and `DIOCNATLOOK` from xnu's `bsd/net/pfvar.h`,
/// which is not in the public SDK: four 16-byte `pf_addr`s, four 4-byte
/// `pf_state_xport` unions (a port in network order in the first two bytes),
/// then `af`, `proto`, `proto_variant` and `direction`, 84 bytes in all.
/// sshuttle uses the same layout. Given the client's and the listener's
/// address and port of an accepted connection, pf fills in where the client
/// was going (`rdaddr`, `rdxport`).
public enum NatLook {
    public static let size = 84
    /// `_IOWR('D', 23, struct pfioc_natlook)`.
    public static let request: UInt = 0xC000_0000 | (UInt(size & 0x1FFF) << 16) | (UInt(UInt8(ascii: "D")) << 8) | 23
    static let pfOut: UInt8 = 2

    /// The request for an IPv4 TCP connection, the addresses as 4 bytes.
    public static func encode(client: [UInt8], clientPort: UInt16, local: [UInt8], localPort: UInt16) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size)
        buffer.replaceSubrange(0..<4, with: client.prefix(4))
        buffer.replaceSubrange(16..<20, with: local.prefix(4))
        put(clientPort, at: 64, in: &buffer)
        put(localPort, at: 68, in: &buffer)
        buffer[80] = UInt8(AF_INET)
        buffer[81] = UInt8(IPPROTO_TCP)
        buffer[83] = pfOut
        return buffer
    }

    /// The original destination in an answered request.
    public static func destination(in buffer: [UInt8]) -> (address: [UInt8], port: UInt16)? {
        guard buffer.count >= size else { return nil }
        let address = Array(buffer[48..<52])
        let port = UInt16(buffer[76]) << 8 | UInt16(buffer[77])
        guard port != 0, address != [0, 0, 0, 0] else { return nil }
        return (address, port)
    }

    private static func put(_ port: UInt16, at offset: Int, in buffer: inout [UInt8]) {
        buffer[offset] = UInt8(port >> 8)
        buffer[offset + 1] = UInt8(port & 0xFF)
    }
}

// MARK: - DNS answers

/// Rewrites the A records of a DNS response in place: a stand-in has the
/// same length as the address, so nothing else in the message moves.
public enum DNSRewrite {
    /// `map` gets each IPv4 address in an answer, authority or additional A
    /// record of class IN and returns its replacement, or nil to keep it. A
    /// replaced record's TTL is cut to `ttlCap`, so that a stand-in does not
    /// outlive the overlap in caches for long. A message that cannot be read
    /// is returned as it came.
    public static func rewriteA(_ message: [UInt8], ttlCap: UInt32? = nil, _ map: ([UInt8]) -> [UInt8]?) -> [UInt8] {
        var out = message
        guard message.count >= 12 else { return message }
        let count = { (at: Int) in Int(message[at]) << 8 | Int(message[at + 1]) }
        let questions = count(4)
        let records = count(6) + count(8) + count(10)
        var offset = 12
        for _ in 0..<questions {
            guard let end = skipName(message, at: offset), end + 4 <= message.count else { return message }
            offset = end + 4
        }
        for _ in 0..<records {
            guard let end = skipName(message, at: offset), end + 10 <= message.count else { return message }
            let type = count(end)
            let klass = count(end + 2)
            let length = count(end + 8)
            let data = end + 10
            guard data + length <= message.count else { return message }
            if type == 1, klass == 1, length == 4, let replacement = map(Array(message[data..<data + 4])), replacement.count == 4 {
                out.replaceSubrange(data..<data + 4, with: replacement)
                let ttl = message[end + 4..<end + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                if let ttlCap, ttl > ttlCap {
                    out.replaceSubrange(end + 4..<end + 8, with: [UInt8(ttlCap >> 24), UInt8(ttlCap >> 16 & 0xFF), UInt8(ttlCap >> 8 & 0xFF), UInt8(ttlCap & 0xFF)])
                }
            }
            offset = data + length
        }
        return out
    }

    /// The offset after a name: labels up to the root, or up to a pointer.
    static func skipName(_ message: [UInt8], at start: Int) -> Int? {
        var offset = start
        for _ in 0..<128 {
            guard offset < message.count else { return nil }
            let length = Int(message[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= message.count ? offset + 2 : nil }
            guard length & 0xC0 == 0 else { return nil }
            offset += 1 + length
        }
        return nil
    }

    /// The question's id, to match a forwarded answer to its query.
    public static func id(_ message: [UInt8]) -> UInt16? {
        message.count >= 2 ? UInt16(message[0]) << 8 | UInt16(message[1]) : nil
    }
}

// MARK: - IPv4 arithmetic

extension IPNetwork {
    /// The IPv4 address as a number, 0 for IPv6.
    var v4: UInt32 {
        guard bytes.count == 4 else { return 0 }
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(v4: UInt32, prefix: Int) {
        self.init(bytes: [UInt8(v4 >> 24), UInt8(v4 >> 16 & 0xFF), UInt8(v4 >> 8 & 0xFF), UInt8(v4 & 0xFF)], prefix: prefix)
    }

    /// Whether the two share any address.
    public func overlaps(_ other: IPNetwork) -> Bool {
        let (wide, narrow) = prefix <= other.prefix ? (self, other) : (other, self)
        return wide.contains(narrow)
    }
}
