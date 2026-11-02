import Foundation

/// The widget's own tunnels: launchd jobs started and stopped through the
/// sudoers rule, watched through the state files their daemons write.
public final class TunnelControllerLaunchd: ConnectionController, ServiceDirectory, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.ya-makariy.vpn-widget.tunnels")

    public init() {}

    // MARK: Directory

    /// Installed tunnels: one per launchd plist of ours.
    public func listVPNServices() async throws -> [DiscoveredService] {
        Self.installedNames().compactMap { name in
            guard let profile = Self.installedProfile(name) else {
                return DiscoveredService(id: TunnelConfig.profileID(name: name), name: name, enabled: true, providerBundleID: nil)
            }
            return DiscoveredService(id: profile.id, name: profile.displayName, enabled: true, providerBundleID: profile.tunnel?.kind.providerBundleID)
        }
    }

    public static func installedNames() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: TunnelFiles.launchDaemonsDirectory)) ?? []
        return entries.compactMap { file in
            guard file.hasPrefix(TunnelFiles.labelPrefix), file.hasSuffix(".plist") else { return nil }
            return String(file.dropFirst(TunnelFiles.labelPrefix.count).dropLast(".plist".count))
        }.sorted()
    }

    /// The profile as installed, from the world-readable copy the helper keeps
    /// next to the state files (the config itself is root-only).
    public static func installedProfile(_ name: String) -> VPNProfile? {
        guard let data = FileManager.default.contents(atPath: TunnelFiles.publicProfilePath(name)) else { return nil }
        return try? TunnelState.decoder.decode(VPNProfile.self, from: data)
    }

    // MARK: Status

    public static func readState(_ name: String) -> TunnelState? {
        guard let data = FileManager.default.contents(atPath: TunnelFiles.statePath(name)) else { return nil }
        return try? TunnelState.decoder.decode(TunnelState.self, from: data)
    }

    static func isAlive(pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    public func status(of serviceID: String) async -> RawConnectionStatus? {
        guard let name = TunnelConfig.name(fromProfileID: serviceID) else { return nil }
        guard FileManager.default.fileExists(atPath: TunnelFiles.plistPath(name)) else { return nil }
        guard let state = Self.readState(name) else { return .disconnected }
        return state.rawStatus(daemonAlive: Self.isAlive(pid: state.pid))
    }

    public func extendedStatus(of serviceID: String) async -> ExtendedStatus? {
        guard let name = TunnelConfig.name(fromProfileID: serviceID), let state = Self.readState(name) else { return nil }
        return ExtendedStatus(
            lastChange: state.connectedSince ?? state.since,
            dnsServers: state.dnsServers,
            dnsSearchDomains: [],
            isPrimaryInterface: false,
            interfaceName: state.interfaceName,
            signInURL: state.signInURL.flatMap(URL.init(string:)),
            signInAttempt: state.signInAttempt,
            message: state.message,
            untrustedCertificate: state.untrustedCertificate
        )
    }

    public func statistics(of serviceID: String) async -> Traffic? {
        guard let name = TunnelConfig.name(fromProfileID: serviceID), let state = Self.readState(name),
              state.phase == .connected, let interface = state.interfaceName
        else { return nil }
        return InterfaceStatistics.traffic(interface: interface)
    }

    // MARK: Actions

    public func start(_ serviceID: String) async throws {
        guard let name = TunnelConfig.name(fromProfileID: serviceID) else { throw ActionError("not a tunnel") }
        try await Self.sudo(TunnelFiles.kickstartCommand(name: name))
    }

    public func stop(_ serviceID: String) async throws {
        guard let name = TunnelConfig.name(fromProfileID: serviceID) else { throw ActionError("not a tunnel") }
        do {
            try await Self.sudo(TunnelFiles.killCommand(name: name))
        } catch let error as ActionError where error.description.contains("No such process") || error.description.contains("not running") {
            return
        }
    }

    static func sudo(_ command: [String]) async throws {
        let (status, output) = try await runProcess("/usr/bin/sudo", Array(command.dropFirst()))
        guard status == 0 else {
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("a password is required") || text.contains("not allowed") {
                throw ActionError("tunnels are not set up for this user: use Set Up Tunnels in Settings")
            }
            throw ActionError(text.isEmpty ? "launchctl failed (\(status))" : text)
        }
    }

    // MARK: Changes

    /// Watches the state directory, so that a daemon writing its file pokes
    /// the engine. The directory may not exist yet; it is retried on each poll.
    public func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        lock.withLock { self.handler = handler }
        armWatcher()
    }

    private func armWatcher() {
        lock.withLock {
            guard watcher == nil else { return }
            let fd = open(TunnelFiles.stateDirectory, O_EVTONLY)
            guard fd >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let handler = self.lock.withLock { self.handler }
                handler?("tunnels")
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.lock.withLock {
                        self.watcher?.cancel()
                        self.watcher = nil
                    }
                }
            }
            source.setCancelHandler { close(fd) }
            watchedDescriptor = fd
            watcher = source
            source.resume()
        }
    }
}

/// Serves several controllers and directories as one, telling the widget's own
/// tunnels from other apps' profiles by the profile id.
public struct CompositeController: ConnectionController, ServiceDirectory {
    public var system: any ConnectionController
    public var systemDirectory: any ServiceDirectory
    public var tunnels: TunnelControllerLaunchd

    public init(system: any ConnectionController, systemDirectory: any ServiceDirectory, tunnels: TunnelControllerLaunchd) {
        self.system = system
        self.systemDirectory = systemDirectory
        self.tunnels = tunnels
    }

    private func controller(for id: String) -> any ConnectionController {
        TunnelConfig.name(fromProfileID: id) == nil ? system : tunnels
    }

    public func listVPNServices() async throws -> [DiscoveredService] {
        let own = (try? await tunnels.listVPNServices()) ?? []
        return try await systemDirectory.listVPNServices() + own
    }

    public func status(of serviceID: String) async -> RawConnectionStatus? { await controller(for: serviceID).status(of: serviceID) }
    public func extendedStatus(of serviceID: String) async -> ExtendedStatus? { await controller(for: serviceID).extendedStatus(of: serviceID) }
    public func statistics(of serviceID: String) async -> Traffic? { await controller(for: serviceID).statistics(of: serviceID) }
    public func start(_ serviceID: String) async throws { try await controller(for: serviceID).start(serviceID) }
    public func stop(_ serviceID: String) async throws { try await controller(for: serviceID).stop(serviceID) }

    public func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        await system.setChangeHandler(handler)
        await tunnels.setChangeHandler(handler)
    }
}

/// Setting up and installing own tunnels through the admin prompt.
@MainActor
public enum TunnelInstaller {
    /// Whether the helper is installed and matches the one in this bundle.
    public enum SetupStatus: Equatable, Sendable {
        case notSetUp
        case outdated
        case ready
    }

    public static var bundledHelper: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vpn-tunnel").path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vpn-tunnel").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func setupStatus() -> SetupStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: TunnelFiles.helperPath), fm.fileExists(atPath: TunnelFiles.sudoersPath) else { return .notSetUp }
        guard let bundled = bundledHelper,
              let a = fm.contents(atPath: bundled), let b = fm.contents(atPath: TunnelFiles.helperPath)
        else { return .ready }
        return a == b ? .ready : .outdated
    }

    public static var homebrewPrefix: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ? "/opt/homebrew" : "/usr/local"
    }

    /// Which tools are missing from Homebrew, so that setup can say so first.
    public static func missingTools() -> [String] {
        let prefix = homebrewPrefix
        var missing: [String] = []
        if !FileManager.default.fileExists(atPath: "\(prefix)/bin/openfortivpn") { missing.append("openfortivpn") }
        if !FileManager.default.fileExists(atPath: "\(prefix)/bin/openconnect") { missing.append("openconnect") }
        return missing
    }

    public static func setUp() throws {
        guard let helper = bundledHelper else { throw ActionError("the helper is missing from the app bundle; run make app") }
        try PrivilegedRunner.run(TunnelFiles.setupScript(bundledHelper: helper, user: NSUserName(), homebrewPrefix: homebrewPrefix))
    }

    private static var stageDirectory: URL {
        ProfileStoreJSON.supportDirectory.appendingPathComponent("tunnel-stage", isDirectory: true)
    }

    /// Installs or updates a tunnel: its profile goes to the root-only config,
    /// the password, if given, to the root-only secrets.
    public static func install(_ profile: VPNProfile, password: String?) throws {
        guard let tunnel = profile.tunnel, TunnelConfig.isValidName(tunnel.name) else { throw ActionError("invalid tunnel name") }
        let fm = FileManager.default
        try fm.createDirectory(at: stageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = stageDirectory.appendingPathComponent("\(tunnel.name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: config, options: .atomic)
        var secret: URL?
        if let password, !password.isEmpty {
            let url = stageDirectory.appendingPathComponent("\(tunnel.name).secret")
            try password.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            secret = url
        }
        defer {
            try? fm.removeItem(at: config)
            if let secret { try? fm.removeItem(at: secret) }
        }
        try PrivilegedRunner.run(TunnelFiles.installScript(name: tunnel.name, stagedConfig: config.path, stagedSecret: secret?.path))
    }

    public static func remove(name: String) throws {
        guard TunnelConfig.isValidName(name) else { throw ActionError("invalid tunnel name") }
        try PrivilegedRunner.run(TunnelFiles.removeScript(name: name))
    }
}
