import Foundation
import VPNWidgetCore

/// What wg-quick would do around amneziawg-go, done here instead: wg-quick
/// daemonizes, needs bash 4, runs the config's hooks as root and sets DNS on
/// every network service. Once amneziawg-go has its utun, this gives awg the
/// config, sets addresses, MTU and routes, then asks awg for the latest
/// handshake every few seconds and tells the runner when the link comes up or
/// goes quiet. When amneziawg-go has exited, `finish` takes the routes away.
final class WireGuardLink: @unchecked Sendable {
    private let name: String
    private let conf: WireGuardConf
    private let child: Process
    private let log: @Sendable (String, TunnelConfig.LogLevel) -> Void
    private let emit: @Sendable (ToolEvent) -> Void
    private let awg = "\(TunnelFiles.libexecDirectory)/awg"

    private let lock = NSLock()
    private var finished = false
    /// The command the watcher is waiting on, so that `finish` can end it.
    private var running: Process?
    private let done = DispatchSemaphore(value: 0)
    private var interface: String?
    private var routes: [IPNetwork] = []
    /// Endpoint host routes: the peer's address, and the gateway it was
    /// routed by ("" for the blackhole that stands in when there is none).
    private var pinned: [IPNetwork: String] = [:]

    init(name: String, conf: WireGuardConf, child: Process, log: @escaping @Sendable (String, TunnelConfig.LogLevel) -> Void, emit: @escaping @Sendable (ToolEvent) -> Void) {
        self.name = name
        self.conf = conf
        self.child = child
        self.log = log
        self.emit = emit
    }

    func start() {
        Thread.detachNewThread { [self] in
            work()
            done.signal()
        }
    }

    /// Called once amneziawg-go has exited: stops watching and removes what
    /// was added outside the interface.
    func finish() {
        // awg can spend a minute resolving an endpoint's name; nobody waits for that.
        let running: Process? = lock.withLock {
            finished = true
            return self.running
        }
        if let running, running.isRunning { running.terminate() }
        done.wait()
        removeRoutes()
        try? FileManager.default.removeItem(atPath: TunnelFiles.interfaceNamePath(name))
    }

    private var isFinished: Bool { lock.withLock { finished } }
    private var isOver: Bool { isFinished || !child.isRunning }

    private func work() {
        guard let interface = waitForInterface() else {
            // amneziawg-go said why on its output, or was stopped.
            if !isOver { fail("amneziawg-go did not report its interface") }
            return
        }
        self.interface = interface
        do {
            try configure(interface)
        } catch {
            fail("\(error)")
            return
        }
        if let address = conf.addresses.first?.address {
            emit(.addresses(ip: address, dns: conf.dnsServers))
        }
        emit(.waiting("Waiting for the first handshake"))
        watch(interface)
    }

    /// Ends the session. When amneziawg-go is gone already, what it said
    /// itself is the better reason, and it is not replaced.
    private func fail(_ reason: String) {
        guard !isOver else { return }
        emit(.error(reason))
        child.terminate()
    }

    private func pause(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !isOver { Thread.sleep(forTimeInterval: 0.25) }
    }

    // MARK: Bringing it up

    /// amneziawg-go writes the utun's name to `WG_TUN_NAME_FILE` when asked
    /// for plain `utun`, then opens its socket for awg.
    private func waitForInterface() -> String? {
        let path = TunnelFiles.interfaceNamePath(name)
        for _ in 0..<60 where !isOver {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let interface = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if WireGuardConf.isInterfaceName(interface), FileManager.default.fileExists(atPath: WireGuardCommands.socketPath(interface: interface)) {
                    return interface
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private func configure(_ interface: String) throws {
        // awg reads the config from a file; it exists, root-only, for as long as awg runs.
        let file = "\(TunnelFiles.generatedDirectory)/\(name).conf"
        try Admin.writeRoot(conf.setconf, to: file, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: file) }
        log("awg setconf \(interface)", .info)
        try run(awg, WireGuardCommands.setconf(interface: interface, file: file), quiet: true)
        for address in conf.addresses {
            try run(WireGuardCommands.ifconfig, WireGuardCommands.addAddress(address, interface: interface))
        }
        if let mtu = conf.mtu {
            try run(WireGuardCommands.ifconfig, WireGuardCommands.setMTU(mtu, interface: interface))
        }
        try run(WireGuardCommands.ifconfig, WireGuardCommands.up(interface: interface))
        for network in conf.routes {
            // A route that is taken, by another tunnel say, is not a reason to give up the rest.
            do {
                try run(WireGuardCommands.route, WireGuardCommands.addRoute(network, interface: interface))
                routes.append(network)
            } catch {
                log("\(error)", .error)
            }
        }
        if conf.takesDefaultRoute, !conf.routesOff {
            log("this tunnel carries the default route: all traffic goes through it", .info)
        }
        pinEndpoints(interface)
    }

    /// Runs a command to its end, or to `finish`.
    private func execute(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started: Bool = lock.withLock {
            guard !finished, (try? process.run()) != nil else { return false }
            running = process
            return true
        }
        guard started else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.withLock { running = nil }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func run(_ path: String, _ arguments: [String], quiet: Bool = false) throws {
        let command = ([(path as NSString).lastPathComponent] + arguments).joined(separator: " ")
        if !quiet { log(command, .info) }
        let (status, output) = execute(path, arguments)
        guard status == 0 else {
            let text = conf.scrub(output).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError("\(quiet ? "awg setconf" : command) failed (\(status))\(text.isEmpty ? "" : ": \(text)")")
        }
    }

    /// A peer whose address falls inside the tunnel's own routes, always so
    /// with the default route, would have its packets sent into the tunnel
    /// that carries them. Such a peer gets a host route by the gateway the
    /// system uses now, as wg-quick gives it; checked again while the tunnel
    /// runs, since the gateway changes with the network.
    private func pinEndpoints(_ interface: String) {
        guard !routes.isEmpty else { return }
        let (status, output) = execute(awg, WireGuardCommands.show(interface: interface, "endpoints"))
        guard status == 0 else { return }
        var wanted: [IPNetwork: String] = [:]
        var gateways: [Bool: String] = [:]
        for endpoint in WireGuardStatus.endpoints(in: output) where routes.contains(where: { $0.contains(endpoint) }) {
            if gateways[endpoint.isIPv6] == nil {
                let table = execute(WireGuardCommands.netstat, WireGuardCommands.routingTable(ipv6: endpoint.isIPv6)).1
                gateways[endpoint.isIPv6] = WireGuardStatus.defaultGateway(inNetstat: table) ?? ""
            }
            wanted[endpoint] = gateways[endpoint.isIPv6]
        }
        for (endpoint, gateway) in pinned where wanted[endpoint] != gateway {
            _ = execute(WireGuardCommands.route, WireGuardCommands.deleteEndpointRoute(endpoint))
            pinned[endpoint] = nil
        }
        for (endpoint, gateway) in wanted where pinned[endpoint] == nil {
            let (added, text) = execute(WireGuardCommands.route, WireGuardCommands.addEndpointRoute(endpoint, gateway: gateway.isEmpty ? nil : gateway))
            // Kept even when the add failed, as wg-quick does: a route left by a daemon that was killed is ours too.
            pinned[endpoint] = gateway
            let how = gateway.isEmpty ? "nowhere: there is no default gateway" : "by \(gateway)"
            log("route to the peer \(endpoint.address) \(how)\(added == 0 ? "" : " (\(text.trimmingCharacters(in: .whitespacesAndNewlines)))")", added == 0 ? .info : .error)
        }
    }

    // MARK: Watching

    private func watch(_ interface: String) {
        var link = WireGuardStatus.Link.waiting
        var polls = 0
        while !isOver {
            let (status, output) = execute(awg, WireGuardCommands.show(interface: interface, "latest-handshakes"))
            if status == 0 {
                let now = WireGuardStatus.link(latestHandshake: WireGuardStatus.latestHandshake(in: output), now: Date())
                if now != link, !isOver {
                    switch now {
                    case .up: emit(.up(interface: interface, address: conf.addresses.first?.address))
                    case .stale, .waiting: emit(.waiting("No handshake for \(Int(WireGuardStatus.handshakeFreshFor / 60)) minutes; waiting for the peer"))
                    }
                    link = now
                }
            }
            polls += 1
            if polls % 6 == 0 { pinEndpoints(interface) }
            pause(link == .up ? 5 : 2)
        }
    }

    // MARK: Taking it down

    /// Routes through the utun go with it when amneziawg-go exits; one that
    /// is still there is deleted, but only while it still points at our
    /// interface: by now the same prefix may belong to another tunnel. The
    /// peers' host routes go by the gateway, so they are always ours to remove.
    private func removeRoutes() {
        if let interface, if_nametoindex(interface) != 0 {
            for network in routes {
                let (status, output) = TunnelRunner.run(WireGuardCommands.route, WireGuardCommands.getRoute(network))
                guard status == 0, WireGuardStatus.routeInterface(inRouteGet: output) == interface else { continue }
                TunnelRunner.run(WireGuardCommands.route, WireGuardCommands.deleteRoute(network))
            }
        }
        routes = []
        for endpoint in pinned.keys {
            TunnelRunner.run(WireGuardCommands.route, WireGuardCommands.deleteEndpointRoute(endpoint))
        }
        if !pinned.isEmpty { log("removed the routes to \(pinned.count == 1 ? "the peer" : "the peers")", .info) }
        pinned = [:]
    }
}

extension Admin {
    /// AmneziaWG: the imported `.conf` is the tunnel's secret. It is checked
    /// here before anything is stored, and what the profile shows of it is
    /// taken from the file itself, not from what the form sent along.
    static func wireGuardConf(name: String, stagedSecret: String?) throws -> WireGuardConf {
        guard let data = FileManager.default.contents(atPath: stagedSecret ?? TunnelFiles.secretPath(name)) else {
            throw ActionError("the tunnel has no .conf yet: import one")
        }
        do {
            return try WireGuardConf.parse(String(decoding: data, as: UTF8.self))
        } catch {
            throw ActionError("the .conf cannot be used: \(error)")
        }
    }
}
