import Foundation
import VPNWidgetCore

/// Stand-in ranges for the networks of this tunnel that another tunnel's
/// route took (issue #13): finds them in the routing table, gives each a range
/// of the documentation networks (kept in a shared table across restarts), adds a route
/// for the real network scoped to our interface, and carries TCP to the
/// range: pf sends it to a listener here, which asks pf where it was going and
/// dials the real address from a socket bound to our interface. A DNS
/// forwarder rewrites the tunnel's split-DNS answers into the ranges.
///
/// One per session: `start` once the interface is up, `stop` when it goes. It
/// checks the table again every little while, since the other tunnel may come
/// or go; a range, once in use, stays until the session ends, so that
/// addresses already handed out keep working.
final class FakeIPService: @unchecked Sendable {
    typealias Log = @Sendable (String, TunnelConfig.LogLevel) -> Void

    private let name: String
    private let interface: String
    /// The networks the tunnel routes: an AmneziaWG tunnel's AllowedIPs, or,
    /// for the other tools, what they put on the interface, learnt as they go
    /// and kept when another tunnel takes one.
    private var wanted: [IPNetwork]
    private let learnsNetworks: Bool
    /// openconnect: the networks the gateway asked for, as the vpnc-script
    /// wrapper recorded them, also those whose route another tunnel had.
    private let recordedRoutes: String?
    private let ownAddress: String?
    private let upstreamDNS: [String]
    private let log: Log
    private let changed: @Sendable () -> Void

    private let lock = NSLock()
    private var stopping = false
    private var active: [IPNetwork: (mapping: FakeIP.Mapping, sharedWith: String)] = [:]
    private var scoped: [IPNetwork] = []
    private var pfToken: String?
    private var proxy: TCPProxy?
    private var dns: DNSForwarder?
    private var recheck: Thread?
    private var warnedNoDNS = false

    /// `wanted` nil: learn the networks from the routes on the interface,
    /// and from `recordedRoutes` when given.
    init(name: String, interface: String, wanted: [IPNetwork]?, recordedRoutes: String? = nil, ownAddress: String?, upstreamDNS: [String], log: @escaping Log, changed: @escaping @Sendable () -> Void) {
        self.name = name
        self.interface = interface
        self.wanted = (wanted ?? []).filter { !$0.isIPv6 }
        learnsNetworks = wanted == nil
        self.recordedRoutes = recordedRoutes
        self.ownAddress = ownAddress
        self.upstreamDNS = upstreamDNS
        self.log = log
        self.changed = changed
    }

    /// What the state file shows.
    var networks: [TunnelState.FakeNetwork] {
        lock.withLock {
            active.values.map { TunnelState.FakeNetwork(real: $0.mapping.real, fake: $0.mapping.fake, sharedWith: $0.sharedWith) }
                .sorted { $0.real < $1.real }
        }
    }

    /// The forwarder's port while the tunnel has stand-ins and DNS to rewrite.
    var dnsPort: UInt16? { lock.withLock { dns?.port } }

    func start() {
        // A daemon killed before it could clean up leaves its rules behind.
        _ = Self.pfctl(["-a", FakeIP.anchor(tunnel: name), "-F", "all"])
        update()
        // Every 20 seconds, and at once when the table (a choice of the user's) changes.
        let thread = Thread { [weak self] in
            var stamp = Self.tableStamp()
            while let self, !self.isStopping {
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline, !self.isStopping, Self.tableStamp() == stamp {
                    Thread.sleep(forTimeInterval: 1)
                }
                stamp = Self.tableStamp()
                if !self.isStopping { self.update() }
            }
        }
        recheck = thread
        thread.start()
    }

    func stop() {
        let (proxy, dns, token, scoped, hadAny): (TCPProxy?, DNSForwarder?, String?, [IPNetwork], Bool) = lock.withLock {
            stopping = true
            defer {
                self.proxy = nil; self.dns = nil; pfToken = nil; self.scoped = []; active = [:]
            }
            return (self.proxy, self.dns, pfToken, self.scoped, !active.isEmpty)
        }
        proxy?.stop()
        dns?.stop()
        if hadAny || token != nil {
            _ = Self.pfctl(["-a", FakeIP.anchor(tunnel: name), "-F", "all"])
        }
        if let token { _ = Self.pfctl(["-X", token]) }
        if if_nametoindex(interface) != 0 {
            for network in scoped { TunnelRunner.run(WireGuardCommands.route, FakeIP.deleteScopedRoute(network, interface: interface)) }
        }
        if hadAny { log("stand-in ranges released", .info) }
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    static func tableStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: TunnelFiles.fakeIPTablePath))?[.modificationDate] as? Date
    }

    // MARK: Checking the table

    private func update() {
        var table = Self.routingTable()
        if learnsNetworks {
            var learnt = FakeIP.networks(on: interface, in: table, ownAddress: ownAddress)
            if let recordedRoutes, let text = try? String(contentsOfFile: recordedRoutes, encoding: .utf8) {
                learnt += text.split(separator: "\n").compactMap { IPNetwork(String($0)).map(\.network) }.filter { !$0.isIPv6 && $0.prefix >= 8 }
            }
            for network in learnt where !wanted.contains(network) {
                wanted.append(network)
            }
        }
        // Networks nobody routes any more come back to us; one the user chose
        // us for is taken from the tunnel that has it.
        let owners = withTable { $0.owners }
        var touched = false
        for action in FakeIP.routeActions(wanted: wanted, me: name, interface: interface, table: table, owners: owners) {
            switch action {
            case .add(let network):
                if TunnelRunner.run(WireGuardCommands.route, ["-n", "add", "-net", network.description, "-interface", interface]).0 == 0 {
                    log("route \(network) is free: added", .info)
                    touched = true
                }
            case .take(let network, let from):
                // Not `route change`: on macOS it leaves the main route where it
                // was and adds interface-scoped copies. The main route (no
                // -ifscope) is deleted and ours added, then checked.
                TunnelRunner.run(WireGuardCommands.route, ["-n", "delete", "-net", network.description])
                let (_, text) = TunnelRunner.run(WireGuardCommands.route, ["-n", "add", "-net", network.description, "-interface", interface])
                let now = Self.routingTable().first { !$0.isScoped && $0.destination == network }
                if now?.interface == interface {
                    log("\(network) taken from \(from), as chosen in Settings", .info)
                } else {
                    log("taking \(network) from \(from) failed: \(now.map { "it is on \($0.interface)" } ?? "no route") \(text.trimmingCharacters(in: .whitespacesAndNewlines))", .error)
                }
                touched = true
            }
        }
        if touched { table = Self.routingTable() }
        var overlaps = FakeIP.overlaps(of: wanted, on: interface, in: table)
        // A range given out before stays in use while the tunnel is up, overlap
        // or not, so that an address written down (a kubeconfig, a bookmark)
        // keeps working when the other tunnel is down.
        // Another interface's own address was once taken for an overlap: such
        // ranges are given up.
        let ownAddresses = Set(table.filter(\.isOwnAddress).map(\.destination))
        let kept = withTable { table in
            table.mappings.removeAll { $0.tunnel == name && ($0.realNetwork.map { ownAddresses.contains($0) } ?? false) }
            return table.mappings.filter { $0.tunnel == name && ($0.fakeNetwork.map(FakeIP.inPools) ?? false) }
        }
        for mapping in kept {
            guard let real = mapping.realNetwork, wanted.contains(where: { $0.prefix <= real.prefix && $0.contains(real) }),
                  !overlaps.contains(where: { $0.network == real }) else { continue }
            overlaps.append(FakeIP.Overlap(network: real, interface: ""))
        }
        let (known, moved): (Set<IPNetwork>, Bool) = lock.withLock {
            var moved = false
            for overlap in overlaps where !overlap.interface.isEmpty {
                if let entry = active[overlap.network], entry.sharedWith != overlap.interface {
                    active[overlap.network] = (entry.mapping, overlap.interface)
                    moved = true
                }
            }
            return (Set(active.keys), moved)
        }
        if moved { changed() }
        let fresh = overlaps.filter { !known.contains($0.network) }
        guard !fresh.isEmpty, !isStopping else { return }

        // Anything already in the pool's space, someone else's, is kept clear of.
        let avoid = table.map(\.destination).filter(FakeIP.inPools)
        let mappings = withTable { table -> [(FakeIP.Overlap, FakeIP.Mapping)] in
            fresh.compactMap { overlap in table.assign(tunnel: name, real: overlap.network, avoid: avoid).map { (overlap, $0) } }
        }
        for overlap in fresh where !mappings.contains(where: { $0.0 == overlap }) {
            log("\(overlap.network) is routed by \(overlap.interface); no stand-in range is free for it", .error)
        }
        guard !mappings.isEmpty else { return }

        for (overlap, mapping) in mappings {
            let (status, text) = TunnelRunner.run(WireGuardCommands.route, FakeIP.addScopedRoute(overlap.network, interface: interface))
            if status == 0 || text.contains("File exists") {
                lock.withLock { scoped.append(overlap.network) }
            } else {
                log("scoped route \(overlap.network) on \(interface): \(text.trimmingCharacters(in: .whitespacesAndNewlines))", .error)
            }
            lock.withLock { active[overlap.network] = (mapping, overlap.interface) }
            if overlap.interface.isEmpty {
                log("\(overlap.network) keeps its stand-in range \(mapping.fake)", .info)
            } else {
                log("\(overlap.network) is routed by \(overlap.interface): reached here as \(mapping.fake)", .info)
            }
        }
        do {
            try ensureProxy()
            try loadRules()
        } catch {
            log("stand-in ranges: \(error)", .error)
        }
        ensureDNS()
        changed()
    }

    static func routingTable() -> [FakeIP.Route] {
        FakeIP.routes(inNetstat: TunnelRunner.run(WireGuardCommands.netstat, WireGuardCommands.routingTable(ipv6: false)).1)
    }

    /// The shared table, read and written under an exclusive lock, so that
    /// two daemons never hand out the same range.
    private func withTable<T>(_ body: (inout FakeIP.Table) -> T) -> T {
        Self.withTable(log: log, body)
    }

    static func withTable<T>(log: Log? = nil, _ body: (inout FakeIP.Table) -> T) -> T {
        let path = TunnelFiles.fakeIPTablePath
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer {
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
        }
        var table = FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(FakeIP.Table.self, from: $0) } ?? FakeIP.Table()
        let before = table
        let result = body(&table)
        if table != before, let data = try? JSONEncoder().encode(table) {
            do { try Admin.writeRoot(data, to: path, mode: 0o600) } catch { log?("\(path): \(error)", .error) }
        }
        // No secrets in it: a copy the widget can read, to show the choices.
        if let data = try? JSONEncoder().encode(table), FileManager.default.contents(atPath: TunnelFiles.publicFakeIPTablePath) != data {
            try? Admin.writeRoot(data, to: TunnelFiles.publicFakeIPTablePath, mode: 0o644)
        }
        return result
    }

    /// The real address behind a stand-in, for the proxy.
    private func realAddress(for fake: [UInt8]) -> IPNetwork? {
        let address = IPNetwork(bytes: fake, prefix: 32)
        return lock.withLock { active.values.lazy.compactMap { $0.mapping.real(for: address) }.first }
    }

    /// The stand-in of a real address, for DNS answers: only while another
    /// tunnel has the network. A range kept from before still carries
    /// connections, but while we have the real network, names resolve to it.
    private func fakeAddress(for real: [UInt8]) -> [UInt8]? {
        let address = IPNetwork(bytes: real, prefix: 32)
        return lock.withLock { active.values.lazy.filter { !$0.sharedWith.isEmpty }.compactMap { $0.mapping.fake(for: address) }.first?.bytes }
    }

    // MARK: pf

    private func ensureProxy() throws {
        guard lock.withLock({ proxy == nil }) else { return }
        let proxy = try TCPProxy(interface: interface, log: log) { [weak self] fake in self?.realAddress(for: fake) }
        lock.withLock { self.proxy = proxy }
        proxy.start()
        log("stand-in proxy listening on 127.0.0.1:\(proxy.port)", .debug)
    }

    private func loadRules() throws {
        let (port, fakes, haveToken): (UInt16?, [IPNetwork], Bool) = lock.withLock {
            (proxy?.port, active.values.compactMap(\.mapping.fakeNetwork), pfToken != nil)
        }
        guard let port else { return }
        if !haveToken {
            // pf counts who wants it on; our reference goes when the session ends.
            let (status, text) = Self.pfctl(["-E"])
            let token = text.split(separator: "\n").first { $0.contains("Token") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            guard status == 0, let token, !token.isEmpty else { throw ActionError("pfctl -E: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
            lock.withLock { pfToken = token }
        }
        let rules = FakeIP.pfRules(fakes: fakes.sorted { $0.description < $1.description }, port: port)
        let (status, text) = Self.pfctl(["-a", FakeIP.anchor(tunnel: name), "-f", "-"], input: rules)
        guard status == 0 else { throw ActionError("pfctl: \(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    @discardableResult
    static func pfctl(_ arguments: [String], input: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let stdin = Pipe()
        p.standardInput = stdin
        do { try p.run() } catch { return (-1, "\(error)") }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // pfctl warns about -f on every load; that is not news.
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.contains("ALTQ") && !$0.contains("-f option") && !$0.contains("present in the main ruleset") && !$0.contains("/etc/pf.conf for further") && !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "pfctl:" }
            .joined(separator: "\n")
        return (p.terminationStatus, text)
    }

    // MARK: DNS

    private func ensureDNS() {
        guard lock.withLock({ dns == nil }) else { return }
        guard !upstreamDNS.isEmpty else {
            if !warnedNoDNS {
                warnedNoDNS = true
                log("names in shared networks resolve to their real addresses, which another tunnel has: give the tunnel split-DNS domains and servers to have them resolve to the stand-ins", .error)
            }
            return
        }
        do {
            let forwarder = try DNSForwarder(upstream: upstreamDNS, interface: interface, log: log, bindsTo: { [weak self] server in
                // An upstream inside a network another tunnel has goes out bound to ours.
                guard let self, let address = IPNetwork(server) else { return false }
                return self.lock.withLock { self.active.keys.contains { $0.contains(address) } }
            }, rewrite: { [weak self] message in
                DNSRewrite.rewriteA(message, ttlCap: 30) { self?.fakeAddress(for: $0) }
            })
            lock.withLock { dns = forwarder }
            forwarder.start()
            log("split DNS through 127.0.0.1:\(forwarder.port), answers in shared networks rewritten to their stand-ins", .info)
        } catch {
            log("DNS forwarder: \(error)", .error)
        }
    }
}

// MARK: - Sockets

enum Socket {
    static func loopback(port: UInt16 = 0) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    static func ipv4(_ bytes: [UInt8], port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes.prefix(4)) }
        return address
    }

    static func bytes(_ address: sockaddr_in) -> [UInt8] {
        withUnsafeBytes(of: address.sin_addr) { Array($0) }
    }

    static func bind(_ fd: Int32, _ address: sockaddr_in) -> Bool {
        var address = address
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    static func name(_ fd: Int32, peer: Bool = false) -> sockaddr_in? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length) }
        }
        return rc == 0 ? address : nil
    }

    /// Bound to an interface: the scoped route there is used, not the main table.
    static func bindToInterface(_ fd: Int32, _ interface: String) -> Bool {
        var index = UInt32(if_nametoindex(interface))
        guard index != 0 else { return false }
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
    }

    /// Waits until the descriptor is readable, or the time is up.
    static func readable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, Int32(timeout * 1000)) > 0
    }

    static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// The listener pf redirects stand-in connections to. Each connection is
/// looked up in pf (DIOCNATLOOK) for its original destination, translated to
/// the real address and dialled from a socket bound to the tunnel's interface;
/// then bytes are copied both ways until either side closes.
final class TCPProxy: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let pf: Int32
    private let interface: String
    private let log: FakeIPService.Log
    private let resolve: @Sendable ([UInt8]) -> IPNetwork?
    private let lock = NSLock()
    private var stopping = false

    init(interface: String, log: @escaping FakeIPService.Log, resolve: @escaping @Sendable ([UInt8]) -> IPNetwork?) throws {
        let pf = open("/dev/pf", O_RDWR)
        guard pf >= 0 else { throw ActionError("cannot open /dev/pf: \(String(cString: strerror(errno)))") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { close(pf); throw ActionError("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        guard Socket.bind(fd, Socket.loopback()), listen(fd, 128) == 0, let bound = Socket.name(fd) else {
            let why = String(cString: strerror(errno))
            close(fd); close(pf)
            throw ActionError("listener: \(why)")
        }
        self.pf = pf
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)
        self.interface = interface
        self.log = log
        self.resolve = resolve
    }

    func start() {
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        lock.withLock { stopping = true }
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func acceptLoop() {
        while !isStopping {
            guard Socket.readable(listener, timeout: 1) else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(listener)
        close(pf)
    }

    private func serve(_ client: Int32) {
        Socket.noSigPipe(client)
        guard let peer = Socket.name(client, peer: true), let local = Socket.name(client) else { close(client); return }
        var request = NatLook.encode(client: Socket.bytes(peer), clientPort: UInt16(bigEndian: peer.sin_port), local: Socket.bytes(local), localPort: UInt16(bigEndian: local.sin_port))
        let looked = request.withUnsafeMutableBytes { ioctl(pf, NatLook.request, $0.baseAddress!) }
        guard looked == 0, let original = NatLook.destination(in: request) else {
            log("stand-in connection without a pf state; closed", .debug)
            close(client)
            return
        }
        guard let real = resolve(original.address) else {
            log("stand-in \(IPNetwork(bytes: original.address, prefix: 32).address) is not ours; closed", .debug)
            close(client)
            return
        }
        guard let upstream = dial(real.bytes, port: original.port) else {
            log("\(real.address):\(original.port) via \(interface): \(String(cString: strerror(errno)))", .debug)
            close(client)
            return
        }
        let pair = Pair(client, upstream)
        Thread.detachNewThread { pair.copy(from: client, to: upstream) }
        pair.copy(from: upstream, to: client)
    }

    /// A connect bound to the tunnel's interface, with a timeout.
    private func dial(_ address: [UInt8], port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        Socket.noSigPipe(fd)
        guard Socket.bindToInterface(fd, interface) else { close(fd); return nil }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var target = Socket.ipv4(address, port: port)
        let rc = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if rc != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&entry, 1, 15_000) > 0 else { close(fd); errno = ETIMEDOUT; return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { close(fd); errno = error; return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// Two sockets copied into each other; closed when both directions end.
    final class Pair: @unchecked Sendable {
        private let a: Int32
        private let b: Int32
        private let lock = NSLock()
        private var open = 2

        init(_ a: Int32, _ b: Int32) {
            self.a = a
            self.b = b
        }

        func copy(from source: Int32, to target: Int32) {
            var buffer = [UInt8](repeating: 0, count: 65536)
            loop: while true {
                let n = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                var sent = 0
                while sent < n {
                    let m = buffer.withUnsafeBytes { write(target, $0.baseAddress! + sent, n - sent) }
                    if m <= 0 { break loop }
                    sent += m
                }
            }
            shutdown(target, SHUT_WR)
            shutdown(source, SHUT_RD)
            let last = lock.withLock { open -= 1; return open == 0 }
            if last {
                close(a)
                close(b)
            }
        }
    }
}

/// A DNS forwarder on 127.0.0.1 for the tunnel's split-DNS domains: each
/// query goes to the upstream servers in turn, and the answer comes back with
/// addresses in shared networks rewritten to their stand-ins. Clients ask
/// over UDP; upstream is asked over UDP, then over TCP when UDP gets nothing.
final class DNSForwarder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let upstream: [String]
    private let interface: String
    private let log: FakeIPService.Log
    private let bindsTo: @Sendable (String) -> Bool
    private let rewrite: @Sendable ([UInt8]) -> [UInt8]
    private let lock = NSLock()
    private var stopping = false

    init(upstream: [String], interface: String, log: @escaping FakeIPService.Log, bindsTo: @escaping @Sendable (String) -> Bool, rewrite: @escaping @Sendable ([UInt8]) -> [UInt8]) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ActionError("socket: \(String(cString: strerror(errno)))") }
        guard Socket.bind(fd, Socket.loopback()), let bound = Socket.name(fd) else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw ActionError("bind: \(why)")
        }
        self.fd = fd
        port = UInt16(bigEndian: bound.sin_port)
        self.upstream = upstream.filter { IPNetwork($0).map { !$0.isIPv6 } ?? false }
        self.interface = interface
        self.log = log
        self.bindsTo = bindsTo
        self.rewrite = rewrite
    }

    func start() {
        Thread.detachNewThread { [self] in loop() }
    }

    func stop() {
        lock.withLock { stopping = true }
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func loop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !isStopping {
            guard Socket.readable(fd, timeout: 1) else { continue }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length) } }
            }
            guard n > 12 else { continue }
            let query = Array(buffer[0..<n])
            let client = from
            Thread.detachNewThread { [self] in answer(query, to: client) }
        }
        close(fd)
    }

    private func answer(_ query: [UInt8], to client: sockaddr_in) {
        for server in upstream {
            // Some networks drop DNS over UDP to public servers and let TCP through.
            guard let reply = ask(server, query) ?? askTCP(server, query) else { continue }
            let out = rewrite(reply)
            var client = client
            _ = out.withUnsafeBytes { bytes in
                withUnsafePointer(to: &client) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            return
        }
        log("DNS: no answer from \(upstream.joined(separator: ", "))", .debug)
    }

    /// The same question over TCP: a two-byte length before each message.
    private func askTCP(_ server: String, _ query: [UInt8]) -> [UInt8]? {
        guard let address = IPNetwork(server), query.count < 65536 else { return nil }
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        Socket.noSigPipe(s)
        if bindsTo(server), !Socket.bindToInterface(s, interface) { return nil }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var target = Socket.ipv4(address.bytes, port: 53)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return nil }
        let framed = [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query
        guard framed.withUnsafeBytes({ write(s, $0.baseAddress, $0.count) }) == framed.count else { return nil }
        func readExactly(_ count: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = out.withUnsafeMutableBytes { read(s, $0.baseAddress! + got, count - got) }
                guard n > 0 else { return nil }
                got += n
            }
            return out
        }
        guard let header = readExactly(2) else { return nil }
        let length = Int(header[0]) << 8 | Int(header[1])
        guard length >= 12, let reply = readExactly(length), DNSRewrite.id(reply) == DNSRewrite.id(query) else { return nil }
        return reply
    }

    private func ask(_ server: String, _ query: [UInt8]) -> [UInt8]? {
        guard let address = IPNetwork(server) else { return nil }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        if bindsTo(server), !Socket.bindToInterface(s, interface) { return nil }
        var target = Socket.ipv4(address.bytes, port: 53)
        let sent = query.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        guard sent == query.count else { return nil }
        let deadline = Date().addingTimeInterval(3)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            guard Socket.readable(s, timeout: max(0.05, deadline.timeIntervalSinceNow)) else { return nil }
            let n = buffer.withUnsafeMutableBytes { recv(s, $0.baseAddress, $0.count, 0) }
            guard n >= 12 else { return nil }
            let reply = Array(buffer[0..<n])
            if DNSRewrite.id(reply) == DNSRewrite.id(query) { return reply }
        }
        return nil
    }
}
