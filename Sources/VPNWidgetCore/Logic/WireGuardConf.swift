import Foundation

/// An IPv4 or IPv6 address with a prefix length, as `Address` and
/// `AllowedIPs` give them. The text is rebuilt from the parsed bytes, so what
/// reaches a command line is never the imported file's own spelling.
public struct IPNetwork: Hashable, Sendable, CustomStringConvertible {
    /// 4 or 16 bytes.
    public let bytes: [UInt8]
    public let prefix: Int

    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2, let bytes = Self.addressBytes(String(parts[0])) else { return nil }
        var prefix = bytes.count * 8
        if parts.count == 2 {
            guard (1...3).contains(parts[1].count), parts[1].allSatisfy({ "0123456789".contains($0) }),
                  let given = Int(parts[1]), given <= prefix
            else { return nil }
            prefix = given
        }
        self.init(bytes: bytes, prefix: prefix)
    }

    init(bytes: [UInt8], prefix: Int) {
        self.bytes = bytes
        self.prefix = prefix
    }

    /// The bytes of an address literal: digits, hex, dots and colons only.
    static func addressBytes(_ text: String) -> [UInt8]? {
        guard !text.isEmpty, text.count <= 45, text.allSatisfy({ "0123456789abcdefABCDEF.:".contains($0) }) else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    public var isIPv6: Bool { bytes.count == 16 }

    /// The address alone, in its canonical spelling.
    public var address: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let done = bytes.withUnsafeBytes { inet_ntop(isIPv6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return done == nil ? "" : String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var description: String { "\(address)/\(prefix)" }

    /// The same prefix with the host bits cleared: what a route is added for.
    public var network: IPNetwork {
        var out = bytes
        for i in out.indices {
            let keep = min(max(prefix - i * 8, 0), 8)
            out[i] &= keep == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        return IPNetwork(bytes: out, prefix: prefix)
    }

    /// Whether an address of the same family falls inside this prefix.
    public func contains(_ other: IPNetwork) -> Bool {
        other.bytes.count == bytes.count && IPNetwork(bytes: other.bytes, prefix: prefix).network.bytes == network.bytes
    }
}

/// Why a `.conf` was refused. The text never quotes a value from the file:
/// it ends up in the form and in the daemon's log.
public struct WireGuardConfError: Error, Equatable, CustomStringConvertible, Sendable {
    public var line: Int?
    public var reason: String

    public init(_ reason: String, line: Int? = nil) {
        self.reason = reason
        self.line = line
    }

    public var description: String { line.map { "line \($0): \(reason)" } ?? reason }
}

/// What the widget keeps and shows of an imported `.conf`: no keys.
public struct WireGuardSummary: Codable, Hashable, Sendable {
    public var endpoints: [String]
    public var addresses: [String]
    public var allowedIPs: [String]
    public var dnsServers: [String]
    public var mtu: Int?
    /// `AllowedIPs` cover everything: `0.0.0.0/0`, `::/0`, or both halves.
    public var defaultRoute: Bool
    /// Every peer has `PersistentKeepalive`, so handshakes keep coming
    /// without traffic.
    public var keepalive: Bool
    /// wg-quick keys in the file that are not acted on: hooks, `SaveConfig`.
    public var ignoredKeys: [String]

    public init(endpoints: [String] = [], addresses: [String] = [], allowedIPs: [String] = [], dnsServers: [String] = [], mtu: Int? = nil, defaultRoute: Bool = false, keepalive: Bool = false, ignoredKeys: [String] = []) {
        self.endpoints = endpoints
        self.addresses = addresses
        self.allowedIPs = allowedIPs
        self.dnsServers = dnsServers
        self.mtu = mtu
        self.defaultRoute = defaultRoute
        self.keepalive = keepalive
        self.ignoredKeys = ignoredKeys
    }
}

/// A wg-quick style `.conf`, split the way wg-quick splits it: the keys that
/// are wg-quick's own (`Address`, `DNS`, `MTU`, `Table`, the hooks,
/// `SaveConfig`) are taken out for the daemon to apply itself, and every other
/// line goes to `awg setconf` as written, including AmneziaWG's obfuscation
/// parameters and any key a newer awg knows and this code does not.
///
/// `PreUp`, `PostUp`, `PreDown` and `PostDown` are never run: the daemon is
/// root and the file is an imported one. They are only reported.
///
/// The value holds the private key (in `setconf` and `secrets`): it is not
/// Codable, and must not be logged or written anywhere but a root-only file.
public struct WireGuardConf: Equatable, Sendable {
    public struct Endpoint: Hashable, Sendable, CustomStringConvertible {
        /// An address literal or a host name.
        public var host: String
        public var port: Int

        public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    }

    public struct Peer: Equatable, Sendable {
        public var endpoint: Endpoint?
        public var allowedIPs: [IPNetwork] = []
        public var keepalive = false
        var hasPublicKey = false
    }

    public var addresses: [IPNetwork] = []
    /// `DNS =` entries that are addresses.
    public var dnsServers: [String] = []
    /// `DNS =` entries that are names: wg-quick's search domains.
    public var dnsSearchDomains: [String] = []
    public var mtu: Int?
    /// `Table = off`: no routes are added.
    public var routesOff = false
    public var peers: [Peer] = []
    public var ignoredKeys: [String] = []
    /// What `awg setconf` gets. Contains the keys.
    public var setconf = ""
    /// The private and preshared keys, to keep them out of logged output.
    public var secrets: [String] = []

    public static let maximumSize = 64 * 1024

    /// wg-quick's own keys, by their lowercased name.
    static let quickKeys: [String: String] = [
        "address": "Address", "dns": "DNS", "mtu": "MTU", "table": "Table", "saveconfig": "SaveConfig",
        "preup": "PreUp", "postup": "PostUp", "predown": "PreDown", "postdown": "PostDown",
    ]

    private enum Section { case none, interface, peer }

    public static func parse(_ text: String) throws -> WireGuardConf {
        guard text.utf8.count <= maximumSize else { throw WireGuardConfError("the file is too large for a tunnel config") }
        guard !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" || $0.value == 0x7F }) else {
            throw WireGuardConfError("the file has control characters in it")
        }
        var conf = WireGuardConf()
        var kept: [String] = []
        var section = Section.none
        var hasPrivateKey = false
        var number = 0
        // By scalars: to Swift a CR LF pair is one character, not a line end.
        for raw in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let line = String(String.UnicodeScalarView(raw.last == "\r" ? raw.dropLast() : raw))
            // As awg reads it: a comment runs from `#` to the end of the line.
            let stripped = (line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                kept.append(line)
                continue
            }
            if stripped.hasPrefix("[") {
                switch stripped.lowercased() {
                case "[interface]": section = .interface
                case "[peer]":
                    section = .peer
                    conf.peers.append(Peer())
                default: throw WireGuardConfError("only [Interface] and [Peer] sections are known", line: number)
                }
                kept.append(line)
                continue
            }
            guard let equals = stripped.firstIndex(of: "=") else { throw WireGuardConfError("expected key = value", line: number) }
            let key = stripped[..<equals].trimmingCharacters(in: .whitespaces)
            let value = stripped[stripped.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 64, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                throw WireGuardConfError("expected key = value", line: number)
            }
            let lower = key.lowercased()
            switch section {
            case .none:
                throw WireGuardConfError("\(key) comes before [Interface]", line: number)
            case .interface:
                if let quick = quickKeys[lower] {
                    try conf.takeQuickKey(quick, value, line: number)
                    continue
                }
                if lower == "privatekey" {
                    guard isKey(value) else { throw WireGuardConfError("PrivateKey is not a 32-byte base64 key", line: number) }
                    conf.secrets.append(value)
                    hasPrivateKey = true
                } else if lower == "presharedkey" {
                    // awg would refuse the line, and quote it while doing so.
                    throw WireGuardConfError("PresharedKey belongs in [Peer]", line: number)
                }
            case .peer:
                try conf.takePeerKey(lower, value, line: number)
            }
            kept.append(line)
        }
        guard hasPrivateKey else { throw WireGuardConfError("[Interface] has no PrivateKey") }
        guard !conf.addresses.isEmpty else { throw WireGuardConfError("[Interface] has no Address") }
        guard !conf.peers.isEmpty, conf.peers.count <= 64 else { throw WireGuardConfError(conf.peers.isEmpty ? "there is no [Peer]" : "too many peers") }
        guard conf.peers.allSatisfy(\.hasPublicKey) else { throw WireGuardConfError("a [Peer] has no PublicKey") }
        guard conf.peers.contains(where: { $0.endpoint != nil }) else { throw WireGuardConfError("no [Peer] has an Endpoint") }
        guard conf.peers.reduce(0, { $0 + $1.allowedIPs.count }) <= 1024 else { throw WireGuardConfError("too many AllowedIPs") }
        conf.setconf = kept.joined(separator: "\n") + "\n"
        return conf
    }

    private mutating func takeQuickKey(_ key: String, _ value: String, line: Int) throws {
        switch key {
        case "Address":
            for item in Self.list(value) {
                guard let address = IPNetwork(item) else { throw WireGuardConfError("Address is not an IP address with an optional /prefix", line: line) }
                if !addresses.contains(address) { addresses.append(address) }
            }
            guard addresses.count <= 16 else { throw WireGuardConfError("too many addresses", line: line) }
        case "DNS":
            for item in Self.list(value) {
                if let server = IPNetwork(item), !item.contains("/") {
                    if !dnsServers.contains(server.address) { dnsServers.append(server.address) }
                } else if let domain = ResolverFiles.normalizeDomain(item) {
                    if !dnsSearchDomains.contains(domain) { dnsSearchDomains.append(domain) }
                } else {
                    throw WireGuardConfError("DNS is neither an IP address nor a domain", line: line)
                }
            }
        case "MTU":
            guard let number = Self.number(value), (576...65535).contains(number) else { throw WireGuardConfError("MTU is not a number from 576 to 65535", line: line) }
            mtu = number
        case "Table":
            switch value.lowercased() {
            case "", "auto", "main": routesOff = false
            case "off": routesOff = true
            default: throw WireGuardConfError("Table can only be auto, main or off on macOS", line: line)
            }
        default:
            // Hooks and SaveConfig: reported, never acted on.
            if !ignoredKeys.contains(key) { ignoredKeys.append(key) }
        }
    }

    private mutating func takePeerKey(_ lower: String, _ value: String, line: Int) throws {
        let index = peers.count - 1
        switch lower {
        case "publickey":
            guard Self.isKey(value) else { throw WireGuardConfError("PublicKey is not a 32-byte base64 key", line: line) }
            peers[index].hasPublicKey = true
        case "presharedkey":
            guard Self.isKey(value) else { throw WireGuardConfError("PresharedKey is not a 32-byte base64 key", line: line) }
            secrets.append(value)
        case "endpoint":
            guard let endpoint = Self.endpoint(value) else { throw WireGuardConfError("Endpoint is not host:port", line: line) }
            peers[index].endpoint = endpoint
        case "allowedips":
            for item in Self.list(value) {
                guard let network = IPNetwork(item)?.network else { throw WireGuardConfError("AllowedIPs is not a list of IP prefixes", line: line) }
                if !peers[index].allowedIPs.contains(network) { peers[index].allowedIPs.append(network) }
            }
        case "privatekey":
            throw WireGuardConfError("PrivateKey belongs in [Interface]", line: line)
        case "persistentkeepalive":
            if value.lowercased() == "off" || value == "0" {
                peers[index].keepalive = false
            } else {
                guard let seconds = Self.number(value), (1...65535).contains(seconds) else { throw WireGuardConfError("PersistentKeepalive is not a number of seconds", line: line) }
                peers[index].keepalive = true
            }
        default:
            break
        }
    }

    // MARK: Values

    static func list(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func number(_ value: String) -> Int? {
        guard (1...6).contains(value.count), value.allSatisfy({ "0123456789".contains($0) }) else { return nil }
        return Int(value)
    }

    /// A Curve25519 or preshared key: 32 bytes in base64.
    static func isKey(_ value: String) -> Bool {
        value.count == 44 && Data(base64Encoded: value)?.count == 32
    }

    /// `host:port`, `192.0.2.1:port` or `[2001:db8::1]:port`.
    public static func endpoint(_ value: String) -> Endpoint? {
        guard let colon = value.lastIndex(of: ":"), let port = number(String(value[value.index(after: colon)...])), (1...65535).contains(port) else { return nil }
        var host = String(value[..<colon])
        if host.hasPrefix("[") {
            guard host.hasSuffix("]"), let address = IPNetwork(String(host.dropFirst().dropLast())), address.isIPv6 else { return nil }
            return Endpoint(host: address.address, port: port)
        }
        if let address = IPNetwork(host), !host.contains("/") {
            guard !address.isIPv6 else { return nil }
            return Endpoint(host: address.address, port: port)
        }
        host = host.lowercased()
        guard (1...253).contains(host.count), host.first?.isLetter == true || host.first?.isNumber == true,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return nil }
        return Endpoint(host: host, port: port)
    }

    /// The name amneziawg-go reports for its interface.
    public static func isInterfaceName(_ name: String) -> Bool {
        guard name.hasPrefix("utun"), (5...9).contains(name.count) else { return false }
        return name.dropFirst(4).allSatisfy { "0123456789".contains($0) }
    }

    // MARK: What the daemon applies

    public var allowedIPs: [IPNetwork] {
        var out: [IPNetwork] = []
        for network in peers.flatMap(\.allowedIPs) where !out.contains(network) { out.append(network) }
        return out
    }

    /// Whether prefixes cover a whole address family: a `/0`, or the two
    /// halves some configs use to stay more specific than the default route.
    public static func coversEverything(_ networks: [IPNetwork], ipv6: Bool) -> Bool {
        let family = networks.filter { $0.isIPv6 == ipv6 }
        if family.contains(where: { $0.prefix == 0 }) { return true }
        let halves = Set(family.filter { $0.prefix == 1 }.map { $0.network.bytes[0] })
        return halves == [0x00, 0x80]
    }

    public var takesDefaultRoute: Bool {
        Self.coversEverything(allowedIPs, ipv6: false) || Self.coversEverything(allowedIPs, ipv6: true)
    }

    /// The routes to add through the tunnel: one per `AllowedIPs` entry, a
    /// `/0` as its two halves, as wg-quick does on macOS, so that the system's
    /// own default route stays in place underneath. None with `Table = off`.
    public var routes: [IPNetwork] {
        guard !routesOff else { return [] }
        var out: [IPNetwork] = []
        for network in allowedIPs {
            let parts: [IPNetwork]
            if network.prefix == 0 {
                var upper = network.bytes
                upper[0] = 0x80
                parts = [IPNetwork(bytes: network.bytes, prefix: 1), IPNetwork(bytes: upper, prefix: 1)]
            } else {
                parts = [network]
            }
            for part in parts where !out.contains(part) { out.append(part) }
        }
        return out
    }

    public var summary: WireGuardSummary {
        WireGuardSummary(
            endpoints: peers.compactMap { $0.endpoint?.description },
            addresses: addresses.map(\.description),
            allowedIPs: allowedIPs.map(\.description),
            dnsServers: dnsServers,
            mtu: mtu,
            defaultRoute: takesDefaultRoute,
            keepalive: peers.allSatisfy(\.keepalive),
            ignoredKeys: ignoredKeys
        )
    }

    /// Text with the keys taken out, for anything a tool printed.
    public func scrub(_ text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "(hidden)") }
    }
}

extension TunnelConfig {
    /// Takes what the profile shows of a `.conf`: the summary, and the first
    /// endpoint as the tunnel's host and port. Done by the form at import and
    /// again by the root side at install, from the file it stores.
    public mutating func apply(_ conf: WireGuardConf) {
        wireGuard = conf.summary
        if let endpoint = conf.peers.compactMap(\.endpoint).first {
            host = endpoint.host
            port = endpoint.port
        }
    }
}
