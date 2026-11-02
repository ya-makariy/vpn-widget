import Foundation
import VPNWidgetCore

/// Keeps one tunnel up until told to stop: waits for the gateway, runs the
/// tool, follows its output into the state file, writes the resolver files
/// while the link is up, and starts again with a backoff after a drop. A
/// SAML sign-in nobody answers is retried quietly, without a new page.
final class TunnelRunner: @unchecked Sendable {
    let name: String
    private(set) var profile: VPNProfile
    let tunnel: TunnelConfig

    private let lock = NSLock()
    private var state: TunnelState
    private var child: Process?
    private var stopping = false
    private var backoff = Backoff()
    private var resolverDomains: [String] = []
    private var signInPromptDue = true
    private var sessionStarted: Date?
    private var sawSignInTimeout = false
    private var fatal: String?
    private var untrustedCertificate: String?
    private var lastError: String?

    init(name: String) throws {
        guard TunnelConfig.isValidName(name) else { throw ActionError("invalid tunnel name") }
        self.name = name
        let data = try Data(contentsOf: URL(fileURLWithPath: TunnelFiles.configPath(name)))
        profile = try TunnelState.decoder.decode(VPNProfile.self, from: data)
        guard let tunnel = profile.tunnel?.normalized else { throw ActionError("not a tunnel profile") }
        self.tunnel = tunnel
        profile.tunnel = tunnel
        state = TunnelState(phase: .starting, since: Date(), pid: getpid())
    }

    // MARK: Lifecycle

    func run() -> Int32 {
        log("starting tunnel \(name) (\(tunnel.kind.rawValue)) to \(tunnel.host):\(tunnel.port)")
        installSignalHandlers()
        write { $0 = TunnelState(phase: .starting, since: Date(), pid: getpid()) }
        while !isStopping {
            guard waitForGateway() else { break }
            let started = Date()
            sessionStarted = nil
            sawSignInTimeout = false
            fatal = nil
            untrustedCertificate = nil
            lastError = nil
            let status = runOnce()
            removeResolverFiles()
            if isStopping { break }
            let lasted = sessionStarted.map { Date().timeIntervalSince($0) } ?? 0
            if let fatal {
                let pin = untrustedCertificate
                write { $0.phase = .failed; $0.since = Date(); $0.message = fatal; $0.untrustedCertificate = pin; $0.connectedSince = nil; $0.interfaceName = nil; $0.signInURL = nil }
                log("\(fatal); not retrying")
                return 1
            }
            if sawSignInTimeout {
                // Nobody signed in: listen again, keep the page the user has.
                signInPromptDue = false
                log("sign-in timed out; listening again")
                continue
            }
            signInPromptDue = true
            let wait = backoff.next(sessionLasted: lasted)
            let reason = lastError ?? "the tool exited with status \(status)"
            log("down after \(Int(Date().timeIntervalSince(started))) s: \(reason); retrying in \(Int(wait)) s")
            write { $0.phase = .connecting; $0.since = Date(); $0.message = "\(reason); retrying in \(Int(wait)) s"; $0.connectedSince = nil; $0.interfaceName = nil; $0.signInURL = nil }
            sleepUnlessStopping(wait)
        }
        write { $0.phase = .stopped; $0.since = Date(); $0.message = nil; $0.connectedSince = nil; $0.interfaceName = nil; $0.signInURL = nil }
        log("stopped")
        return 0
    }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signalSources.append(source)
        }
    }

    private var signalSources: [DispatchSourceSignal] = []

    private func stop() {
        let child: Process? = lock.withLock {
            stopping = true
            return self.child
        }
        log("stopping")
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }

    private func sleepUnlessStopping(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !isStopping {
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    // MARK: One session

    /// Waits until the gateway's port answers, so that a sign-in page never
    /// opens just to show an error.
    private func waitForGateway() -> Bool {
        var announced = false
        while !isStopping {
            if TCPProbe.canConnect(host: tunnel.host, port: tunnel.port, timeout: 3) { return true }
            if !announced {
                write { $0.phase = .waitingForGateway; $0.since = Date(); $0.message = "waiting for the gateway to answer" }
                log("gateway \(tunnel.host):\(tunnel.port) does not answer; waiting")
                announced = true
            }
            sleepUnlessStopping(2)
        }
        return false
    }

    private func runOnce() -> Int32 {
        let launch: Drivers.Launch
        do {
            launch = try Drivers.launch(for: profile)
        } catch {
            fatal = "\(error)"
            return 1
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input
        lock.withLock { child = process }
        write { $0.phase = .connecting; $0.since = Date(); $0.message = nil; $0.signInURL = nil }
        do {
            try process.run()
        } catch {
            lastError = "cannot run \(launch.executable): \(error.localizedDescription)"
            lock.withLock { child = nil }
            return 1
        }
        if let data = launch.stdin { input.fileHandleForWriting.write(data) }
        try? input.fileHandleForWriting.close()
        log("started \(launch.executable) (pid \(process.processIdentifier))")

        let reader = LineReader(handle: output.fileHandleForReading)
        while let line = reader.next() {
            log("  " + line)
            if let event = launch.parse(line) { handle(event) }
        }
        process.waitUntilExit()
        lock.withLock { child = nil }
        return process.terminationStatus
    }

    private func handle(_ event: ToolEvent) {
        switch event {
        case .signInURL(let url):
            let prompt = signInPromptDue
            write {
                $0.phase = .waitingForSignIn
                $0.since = Date()
                $0.signInURL = url
                if prompt { $0.signInAttempt += 1 }
                $0.message = "Sign in in the browser"
            }
            signInPromptDue = false
        case .signInTimedOut:
            sawSignInTimeout = true
        case .addresses(let ip, let dns):
            write { $0.dnsServers = dns; $0.message = "got address \(ip)" }
        case .up(let interface, let address):
            sessionStarted = Date()
            backoff.reset()
            let name = interface ?? guessInterface(address: address)
            // DNS first, state second: the widget checks the service as soon
            // as it sees "connected", and a lookup that goes out before the
            // resolver files exist comes back NXDOMAIN and gets cached.
            write { $0.interfaceName = name }
            writeResolverFiles()
            write {
                $0.phase = .connected
                $0.since = Date()
                $0.connectedSince = Date()
                $0.interfaceName = name
                $0.signInURL = nil
                $0.message = nil
            }
            signInPromptDue = true
        case .down(let why):
            lastError = why
        case .authenticationFailed(let why):
            fatal = "Authentication failed: \(why)"
            lastError = why
        case .untrustedCertificate(let value):
            untrustedCertificate = value
            fatal = "The gateway's certificate is not trusted"
            lastError = fatal
        case .error(let why):
            lastError = why
        }
    }

    /// pppd names its interface after the first free ppp number; the tool may
    /// not say which. Pick the one that just came up.
    private func guessInterface(address: String?) -> String? {
        // The interface may appear a moment after the tool says it is up.
        for _ in 0..<10 {
            if let address, let name = InterfaceStatistics.interface(withAddress: address) { return name }
            if tunnel.kind == .openfortivpn {
                for i in 0..<8 where InterfaceStatistics.isUp(interface: "ppp\(i)") { return "ppp\(i)" }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    // MARK: Split DNS

    private func writeResolverFiles() {
        guard !profile.dnsDomains.isEmpty else { return }
        var servers = profile.dnsServers.filter(ResolverFiles.isServer)
        if servers.isEmpty { servers = currentState.dnsServers }
        if servers.isEmpty, tunnel.kind == .openconnect, let pushed = readPushedDNS() { servers = pushed }
        guard !servers.isEmpty else {
            log("no DNS servers for the split domains; nothing written")
            return
        }
        var copy = profile
        copy.dnsServers = servers
        let files = ResolverFiles.render(profiles: [copy])
        do {
            try FileManager.default.createDirectory(atPath: ResolverFiles.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            for (domain, content) in files {
                let path = "\(ResolverFiles.directory)/\(domain)"
                if let existing = try? String(contentsOfFile: path, encoding: .utf8), !existing.contains(ResolverFiles.marker) {
                    log("leaving \(path) alone: not ours")
                    continue
                }
                try Admin.writeRoot(content, to: path, mode: 0o644)
                resolverDomains.append(domain)
            }
            write { $0.dnsServers = servers }
            log("split DNS: \(files.keys.sorted().joined(separator: ", ")) → \(servers.joined(separator: ", "))")
        } catch {
            log("resolver files: \(error)")
        }
        if let interface = currentState.interfaceName {
            routeDNSServers(servers, via: interface)
        }
        flushDNSCache()
    }

    private func removeResolverFiles() {
        for domain in resolverDomains {
            let path = "\(ResolverFiles.directory)/\(domain)"
            if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing.contains(ResolverFiles.marker) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        if !resolverDomains.isEmpty { flushDNSCache() }
        resolverDomains = []
        for server in routedServers {
            _ = Self.run("/sbin/route", ["-n", "delete", "-host", server])
        }
        routedServers = []
    }

    private var routedServers: [String] = []

    /// The gateway's DNS servers have to be reachable through the tunnel; a
    /// gateway does not always push a route to them, and the vpnc-script
    /// wrapper hides the DNS from vpnc-script on purpose.
    private func routeDNSServers(_ servers: [String], via interface: String) {
        for server in servers where !server.contains(":") {
            let (status, output) = Self.run("/sbin/route", ["-n", "get", server])
            let via = output.split(separator: "\n").first { $0.contains("interface:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
            if status == 0, via == interface { continue }
            let (added, text) = Self.run("/sbin/route", ["-n", "add", "-host", server, "-interface", interface])
            if added == 0 {
                routedServers.append(server)
                log("route to DNS \(server) via \(interface)")
            } else {
                log("route to DNS \(server): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// mDNSResponder notices new resolver files, but keeps cached answers,
    /// including the negative ones from before the tunnel.
    private func flushDNSCache() {
        _ = Self.run("/usr/bin/dscacheutil", ["-flushcache"])
        _ = Self.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// What the vpnc-script wrapper recorded: DNS servers, then the domain.
    private func readPushedDNS() -> [String]? {
        guard let text = try? String(contentsOfFile: "\(TunnelFiles.stateDirectory)/\(name).dns", encoding: .utf8) else { return nil }
        let servers = text.split(separator: "\n").first.map { $0.split(separator: " ").map(String.init).filter(ResolverFiles.isServer) } ?? []
        return servers.isEmpty ? nil : servers
    }

    // MARK: State file

    private var currentState: TunnelState { lock.withLock { state } }

    private func write(_ change: (inout TunnelState) -> Void) {
        let snapshot: TunnelState = lock.withLock {
            change(&state)
            state.pid = getpid()
            state.updated = Date()
            return state
        }
        do {
            try FileManager.default.createDirectory(atPath: TunnelFiles.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            try Admin.writeRoot(try TunnelState.encoder.encode(snapshot), to: TunnelFiles.statePath(name), mode: 0o644)
        } catch {
            log("state file: \(error)")
        }
    }

    private func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp) \(text)")
        fflush(stdout)
    }
}

/// Lines from a pipe, blocking, until it closes.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false

    init(handle: FileHandle) { self.handle = handle }

    func next() -> String? {
        while true {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                return String(decoding: line, as: UTF8.self)
            }
            if closed {
                guard !buffer.isEmpty else { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            let chunk = handle.availableData
            if chunk.isEmpty { closed = true } else { buffer.append(chunk) }
        }
    }
}

/// A TCP connect with a timeout, to see whether the gateway answers.
enum TCPProbe {
    static func canConnect(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                defer { close(fd) }
                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
                if rc == 0 { return true }
                if errno == EINPROGRESS {
                    var set = fd_set()
                    __darwin_fd_zero(&set)
                    __darwin_fd_set(fd, &set)
                    var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
                    if select(fd + 1, nil, &set, nil, &wait) > 0 {
                        var error: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                        if error == 0 { return true }
                    }
                }
            }
            info = ai.pointee.ai_next
        }
        return false
    }
}

private func __darwin_fd_zero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

private func __darwin_fd_set(_ fd: Int32, _ set: inout fd_set) {
    let index = Int(fd) / 32
    let bit = Int32(1) << (fd % 32)
    withUnsafeMutablePointer(to: &set.fds_bits) { pointer in
        pointer.withMemoryRebound(to: Int32.self, capacity: 32) { $0[index] |= bit }
    }
}
