import AppKit
import Foundation
import Observation
import VPNWidgetCore

/// The app's state for the views: snapshots from the engine turned into rows,
/// the profiles the user configured, and the actions. Everything here is on
/// the main actor; the engine does the work elsewhere.
@Observable
@MainActor
final class AppModel {
    private(set) var rows: [ProfileRowState] = []
    private(set) var aggregate: AggregateState = .empty
    private(set) var discovered: [DiscoveredService] = []
    private(set) var config: StoredConfig
    private(set) var busy: Set<String> = []
    private(set) var blinkOn = true
    private(set) var lastPoll: Date?
    private(set) var resolverStatuses: [String: ResolverFiles.Status] = [:]
    private(set) var tunnelSetupStatus: TunnelInstaller.SetupStatus = .notSetUp
    /// An error from a settings action, for the settings window to show.
    var settingsError: String?
    let settings: SettingsStore
    let isFake: Bool

    private let store: ProfileStoreJSON
    private let engine: PollEngine
    private let notifier: GatedNotifier
    private var pending: [String: PendingAction] = [:]
    /// The last sign-in attempt whose page was opened, per profile.
    private var openedSignIn: [String: Int] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var ticker: Task<Void, Never>?

    private struct PendingAction {
        var phase: ConnectionPhase
        var before: ConnectionPhase
        var until: Date
    }

    /// `VPNWIDGET_PROFILES=<path>` reads and writes another profiles file, for
    /// trying things without touching the real settings.
    static var defaultStore: ProfileStoreJSON {
        if let path = ProcessInfo.processInfo.environment["VPNWIDGET_PROFILES"], !path.isEmpty {
            return ProfileStoreJSON(url: URL(fileURLWithPath: path))
        }
        return ProfileStoreJSON()
    }

    init(store: ProfileStoreJSON = AppModel.defaultStore, settings: SettingsStore = SettingsStore(), fake: Bool = ProcessInfo.processInfo.environment["VPNWIDGET_FAKE"] != nil) {
        self.store = store
        self.settings = settings
        self.isFake = fake
        var loaded = (try? store.load()) ?? StoredConfig()
        let gated = GatedNotifier(fake ? LogNotifier() : NotifierUN())
        gated.setEnabled(settings.notificationsEnabled)
        notifier = gated

        var configuration = PollEngine.Configuration()
        configuration.pollInterval = .seconds(settings.pollIntervalSeconds)
        let ports: PollEngine.Ports
        if fake {
            let system = FakeSystem()
            ports = PollEngine.Ports(directory: system, controller: system, interfaces: system, checker: system, notifier: gated)
            if loaded.profiles.isEmpty { loaded = StoredConfig(profiles: FakeSystem.profiles) }
        } else {
            let composite = CompositeController(system: ConnectionControllerSC(), systemDirectory: ServiceDirectorySC(), tunnels: TunnelControllerLaunchd())
            ports = PollEngine.Ports(
                directory: composite,
                controller: composite,
                interfaces: InterfaceMapSC(),
                checker: ReachabilityCheckerURLSession(),
                notifier: gated,
                hooks: SystemProviderHooks()
            )
        }
        config = loaded
        engine = PollEngine(profiles: loaded.profiles, ports: ports, configuration: configuration)
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [engine] in await engine.run() })
        tasks.append(Task { [weak self, engine] in
            for await snapshot in await engine.snapshots() {
                guard let self else { return }
                let services = await engine.discovered
                self.apply(snapshot, discovered: services)
            }
        })
        tasks.append(Task { [engine] in await engine.autoConnect() })
        refreshResolverStatuses()
        refreshTunnelSetupStatus()
    }

    // MARK: Snapshots

    private func apply(_ snapshot: Snapshot, discovered services: [DiscoveredService]) {
        let now = Date()
        lastPoll = snapshot.at
        discovered = services
        var newRows: [ProfileRowState] = []
        for p in snapshot.profiles {
            var row = ProfileRowState(p, now: now)
            if let pendingAction = pending[row.id] {
                if now < pendingAction.until, row.phase == pendingAction.before {
                    row.phase = pendingAction.phase
                } else {
                    pending[row.id] = nil
                }
            }
            newRows.append(row)
        }
        rows = newRows
        aggregate = AggregateState(snapshot: snapshot)
        updateTicker()
        openPendingSignIns()
        refreshTunnelSetupStatus()
    }

    /// Opens the SAML page of an own tunnel in the browser, once per attempt.
    private func openPendingSignIns() {
        for row in rows {
            guard let url = row.signInURL, row.phase == .waitingForSignIn else {
                if row.phase.isUp || row.phase == .disconnected { openedSignIn[row.id] = nil }
                continue
            }
            if openedSignIn[row.id] != row.signInAttempt {
                openedSignIn[row.id] = row.signInAttempt
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openSignInPage(_ id: String) {
        guard let url = rows.first(where: { $0.id == id })?.signInURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Which shown profiles are up, in panel order, for the icon's ring.
    var segments: [Bool] { rows.map(\.phase.isUp) }

    var connectedCount: Int { rows.filter(\.phase.isUp).count }

    // MARK: Actions

    func connect(_ id: String) { act(.connect, on: id, optimistic: .connecting) }
    func disconnect(_ id: String) { act(.disconnect, on: id, optimistic: .disconnecting) }
    func reconnect(_ id: String) { act(.reconnect, on: id, optimistic: .disconnecting) }

    private func act(_ action: VPNAction, on id: String, optimistic: ConnectionPhase) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        pending[id] = PendingAction(phase: optimistic, before: row.phase, until: Date().addingTimeInterval(4))
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].phase = optimistic }
        busy.insert(id)
        Task { [engine] in
            await engine.perform(action, on: id)
            busy.remove(id)
        }
    }

    func connectAll() {
        for row in rows where row.phase.canConnect {
            pending[row.id] = PendingAction(phase: .connecting, before: row.phase, until: Date().addingTimeInterval(4))
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].phase = .connecting }
        }
        Task { [engine] in await engine.connectAll() }
    }

    func refresh() {
        Task { [engine] in await engine.poke() }
    }

    var canConnectAll: Bool { rows.contains { $0.phase.canConnect } }

    // MARK: Profiles

    func isShown(_ serviceID: String) -> Bool {
        config.profiles.contains { $0.id == serviceID }
    }

    func profile(_ serviceID: String) -> VPNProfile? {
        config.profiles.first { $0.id == serviceID }
    }

    func setShown(_ service: DiscoveredService, _ shown: Bool) {
        var profiles = config.profiles
        if shown, !profiles.contains(where: { $0.id == service.id }) {
            profiles.append(VPNProfile(adopting: service))
        } else if !shown {
            profiles.removeAll { $0.id == service.id }
        }
        saveProfiles(profiles)
    }

    func update(_ profile: VPNProfile) {
        var profiles = config.profiles
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        saveProfiles(profiles)
    }

    func moveProfiles(fromOffsets: IndexSet, toOffset: Int) {
        var profiles = config.profiles
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveProfiles(profiles)
    }

    /// Copies the DNS servers and search domains of the live connection into
    /// the profile's split-DNS settings.
    func fillDNS(from id: String) {
        guard var profile = profile(id), let row = rows.first(where: { $0.id == id }) else { return }
        if !row.dnsServers.isEmpty { profile.dnsServers = row.dnsServers }
        if !row.dnsSearchDomains.isEmpty { profile.dnsDomains = row.dnsSearchDomains }
        update(profile)
    }

    private func saveProfiles(_ profiles: [VPNProfile]) {
        config.profiles = profiles
        persist()
        Task { [engine] in await engine.setProfiles(profiles) }
        refreshResolverStatuses()
    }

    private func persist() {
        do {
            try store.save(config)
        } catch {
            settingsError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    // MARK: Settings

    var pollIntervalSeconds: Int {
        get { settings.pollIntervalSeconds }
        set {
            settings.pollIntervalSeconds = newValue
            Task { [engine] in await engine.setPollInterval(.seconds(newValue)) }
        }
    }

    var notificationsEnabled: Bool {
        get { settings.notificationsEnabled }
        set {
            settings.notificationsEnabled = newValue
            notifier.setEnabled(newValue)
        }
    }

    var launchAtLoginAvailable: Bool { LoginItem.isAvailable && !isFake }

    var launchAtLogin: Bool {
        get { launchAtLoginAvailable && LoginItem.isEnabled }
        set {
            do {
                try LoginItem.setEnabled(newValue)
            } catch {
                settingsError = "Could not change the login item: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Split DNS

    var renderedResolverFiles: [String: String] { ResolverFiles.render(profiles: config.profiles) }

    func refreshResolverStatuses() {
        resolverStatuses = ResolverInstaller.statuses(rendered: renderedResolverFiles, managed: config.managedResolverDomains)
    }

    var resolverFilesUpToDate: Bool {
        ResolverInstaller.isUpToDate(rendered: renderedResolverFiles, managed: config.managedResolverDomains)
    }

    func resolverStatus(for profile: VPNProfile) -> ResolverFiles.Status? {
        let domains = profile.dnsDomains.compactMap(ResolverFiles.normalizeDomain)
        guard !domains.isEmpty, !profile.dnsServers.isEmpty else { return nil }
        let statuses = domains.map { resolverStatuses[$0] ?? .notInstalled }
        if statuses.contains(.foreign) { return .foreign }
        if statuses.allSatisfy({ $0 == .installed }) { return .installed }
        if statuses.allSatisfy({ $0 == .notInstalled }) { return .notInstalled }
        return .outOfDate
    }

    func installResolverFiles() {
        do {
            let managed = try ResolverInstaller.apply(rendered: renderedResolverFiles, managed: config.managedResolverDomains)
            config.managedResolverDomains = managed
            persist()
            settingsError = nil
        } catch {
            let text = "\(error)"
            if text != "cancelled" { settingsError = "Resolver files: \(text)" }
        }
        refreshResolverStatuses()
    }

    func removeResolverFiles() {
        do {
            try ResolverInstaller.removeAll(managed: config.managedResolverDomains)
            config.managedResolverDomains = []
            persist()
            settingsError = nil
        } catch {
            let text = "\(error)"
            if text != "cancelled" { settingsError = "Resolver files: \(text)" }
        }
        refreshResolverStatuses()
    }

    // MARK: Own tunnels

    func refreshTunnelSetupStatus() {
        tunnelSetupStatus = isFake ? .ready : TunnelInstaller.setupStatus()
    }

    var missingTunnelTools: [String] { isFake ? [] : TunnelInstaller.missingTools() }

    /// Profiles that are own tunnels, shown or not.
    var ownTunnels: [VPNProfile] { config.profiles.filter(\.isOwnTunnel) }

    func setUpTunnels() {
        do {
            try TunnelInstaller.setUp()
            settingsError = nil
        } catch {
            let text = "\(error)"
            if text != "cancelled" { settingsError = "Set up tunnels: \(text)" }
        }
        refreshTunnelSetupStatus()
        refresh()
    }

    /// Installs a new or changed tunnel through the admin prompt, then shows
    /// it in the panel.
    func saveTunnel(_ profile: VPNProfile, password: String?) -> Bool {
        guard profile.isOwnTunnel else { return false }
        do {
            try TunnelInstaller.install(profile, password: password)
        } catch {
            let text = "\(error)"
            if text != "cancelled" { settingsError = "Install tunnel: \(text)" }
            return false
        }
        var profiles = config.profiles
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles(profiles)
        settingsError = nil
        return true
    }

    func removeTunnel(_ id: String) {
        guard let name = TunnelConfig.name(fromProfileID: id) else { return }
        do {
            try TunnelInstaller.remove(name: name)
        } catch {
            let text = "\(error)"
            if text != "cancelled" { settingsError = "Remove tunnel: \(text)" }
            return
        }
        saveProfiles(config.profiles.filter { $0.id != id })
        settingsError = nil
    }

    /// Pins the certificate the tunnel's daemon reported as untrusted, applies
    /// the change (admin prompt) and connects again.
    func trustCertificate(_ id: String) {
        guard var profile = profile(id), var tunnel = profile.tunnel,
              let value = rows.first(where: { $0.id == id })?.untrustedCertificate
        else { return }
        tunnel.trustedCert = value
        profile.tunnel = tunnel
        if saveTunnel(profile, password: nil) { connect(id) }
    }

    /// Whether the daemon's copy of a tunnel's profile differs from the
    /// settings here, so that DNS or check changes still need applying.
    func tunnelNeedsApply(_ profile: VPNProfile) -> Bool {
        guard let name = TunnelConfig.name(fromProfileID: profile.id) else { return false }
        guard let installed = TunnelControllerLaunchd.installedProfile(name) else { return true }
        var a = installed
        var b = profile
        a.tunnel?.hasSecret = false
        b.tunnel?.hasSecret = false
        return a != b
    }

    // MARK: Icon animation

    private func updateTicker() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if aggregate.animates, !reduceMotion {
            guard ticker == nil else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let self else { return }
                    self.blinkOn.toggle()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            blinkOn = true
        }
    }
}

/// Prints notices instead of showing them, for the fake system.
struct LogNotifier: Notifier {
    func send(_ notice: Notice) async {
        NSLog("notice: %@ %@", notice.summary, notice.body)
    }
}
