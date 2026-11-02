import Foundation

/// Gathers snapshots: polls everything in parallel every `pollInterval`, or
/// every `recheckInterval` while a check is doubtful, and again when poked by
/// an action or a system notification.
public actor PollEngine {
    public struct Configuration: Sendable {
        public var pollInterval: Duration = .seconds(30)
        public var recheckInterval: Duration = .seconds(1)
        public var failGrace: TimeInterval = 10
        /// How long a new tunnel may fail its check and still count as
        /// connecting: DNS, for one, is set a moment after the link appears.
        public var settleFor: TimeInterval = 30
        /// How long Reconnect waits for the tunnel to go down before starting it.
        public var reconnectWait: Duration = .seconds(10)
        /// When to look again after an action.
        public var repollAfter: [Duration] = [.seconds(3), .seconds(10)]
        /// How long a connection handed to the client's own window counts as
        /// connecting while the system still says disconnected.
        public var handoffTimeout: TimeInterval = 180

        public init() {}
    }

    public struct Ports: Sendable {
        public var directory: any ServiceDirectory
        public var controller: any ConnectionController
        public var interfaces: any InterfaceMap
        public var checker: any ReachabilityChecker
        public var notifier: any Notifier
        public var hooks: any ProviderHooks
        public var now: @Sendable () -> Date

        public init(
            directory: any ServiceDirectory,
            controller: any ConnectionController,
            interfaces: any InterfaceMap,
            checker: any ReachabilityChecker,
            notifier: any Notifier,
            hooks: any ProviderHooks = DefaultProviderHooks(),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.directory = directory
            self.controller = controller
            self.interfaces = interfaces
            self.checker = checker
            self.notifier = notifier
            self.hooks = hooks
            self.now = now
        }
    }

    public private(set) var configuration: Configuration
    private let ports: Ports
    private var profiles: [VPNProfile]
    private var tracker: FailureTracker
    private var changes = ChangeTracker()

    public private(set) var discovered: [DiscoveredService] = []
    public private(set) var latest: Snapshot?

    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var sleeper: Task<Void, Never>?
    private var pokePending = false
    private var running = false
    private var actionErrors: [String: String] = [:]
    /// When each profile was first seen connected, for uptime when the system
    /// gives no `LastStatusChangeTime`, and for the settle grace.
    private var firstConnected: [String: Date] = [:]
    private var transitionSince: [String: Date] = [:]
    private var lastState: [String: ConnectionState] = [:]
    /// Profiles whose connection was handed to the client's window, and when.
    private var handedOff: [String: (since: Date, hint: String)] = [:]

    public init(profiles: [VPNProfile], ports: Ports, configuration: Configuration = Configuration()) {
        self.profiles = profiles
        self.ports = ports
        self.configuration = configuration
        self.tracker = FailureTracker(failGrace: configuration.failGrace)
    }

    // MARK: Profiles and configuration

    public var currentProfiles: [VPNProfile] { profiles }

    public func setProfiles(_ new: [VPNProfile]) {
        guard new != profiles else { return }
        profiles = new
        poke()
    }

    public func setPollInterval(_ interval: Duration) {
        configuration.pollInterval = interval
        poke()
    }

    // MARK: Snapshots

    /// Every snapshot from now on, starting with the latest one if any.
    public func snapshots() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        if let latest { continuation.yield(latest) }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func publish(_ snapshot: Snapshot) {
        latest = snapshot
        for c in subscribers.values { c.yield(snapshot) }
    }

    // MARK: Loop

    /// Polls until cancelled. Call once.
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        await ports.controller.setChangeHandler { [weak self] _ in
            Task { await self?.poke() }
        }
        await ports.interfaces.setChangeHandler { [weak self] in
            Task { await self?.poke() }
        }
        while !Task.isCancelled {
            let snapshot = await poll()
            publish(snapshot)
            for notice in changes.next(snapshot) {
                await ports.notifier.send(notice)
            }
            let wait = snapshot.doubtful ? configuration.recheckInterval : configuration.pollInterval
            await sleepUnlessPoked(wait)
        }
    }

    /// Looks again as soon as possible.
    public func poke() {
        if let sleeper {
            sleeper.cancel()
        } else {
            pokePending = true
        }
    }

    private func sleepUnlessPoked(_ duration: Duration) async {
        if pokePending {
            pokePending = false
            return
        }
        let task = Task<Void, Never> { try? await Task.sleep(for: duration) }
        sleeper = task
        await task.value
        sleeper = nil
    }

    // MARK: Polling

    public func poll() async -> Snapshot {
        if let services = try? await ports.directory.listVPNServices() {
            discovered = services
        }
        let known = Set(discovered.map(\.id))
        let now = ports.now()
        let states = await withTaskGroup(of: (Int, ProfileState).self, returning: [ProfileState].self) { group in
            for (i, profile) in profiles.enumerated() {
                group.addTask { (i, await self.pollProfile(profile, inDirectory: known.contains(profile.id), now: now)) }
            }
            var out = [ProfileState?](repeating: nil, count: profiles.count)
            for await (i, state) in group { out[i] = state }
            return out.compactMap { $0 }
        }
        return Snapshot(profiles: states, at: now)
    }

    private func pollProfile(_ profile: VPNProfile, inDirectory: Bool, now: Date) async -> ProfileState {
        let raw = await ports.controller.status(of: profile.id)
        var state = ProfileState(profile: profile, state: deriveState(raw: raw, inDirectory: inDirectory))
        state.lastActionError = actionErrors[profile.id]
        state.transitionSince = noteTransition(profile.id, state.state, now: now)
        if let handoff = handedOff[profile.id] {
            if state.state == .connected || now.timeIntervalSince(handoff.since) > configuration.handoffTimeout {
                handedOff[profile.id] = nil
            } else if state.state == .disconnected || state.state == .invalid || state.state == .connecting {
                // The client's window is doing the work; the system says nothing yet.
                state.state = .connecting
                state.transitionSince = handoff.since
                state.clientHint = handoff.hint
            }
        }
        let key = profile.id
        guard state.state == .connected else {
            tracker.forget(key: key)
            firstConnected[profile.id] = nil
            if profile.isOwnTunnel, let extended = await ports.controller.extendedStatus(of: profile.id) {
                state.failure = state.state == .failed ? extended.message : nil
                if state.state == .connecting, let url = extended.signInURL {
                    state.signInURL = url
                    state.signInAttempt = extended.signInAttempt
                    state.clientHint = extended.message ?? "Sign in in the browser"
                    state.transitionSince = state.transitionSince ?? extended.lastChange
                } else if state.state == .connecting, let message = extended.message {
                    state.clientHint = message
                }
            }
            return state
        }

        let extended = await ports.controller.extendedStatus(of: profile.id)
        let link = await ports.interfaces.link(for: profile.id)
        let since = extended?.lastChange ?? firstConnected[profile.id] ?? now
        firstConnected[profile.id] = since
        state.connectedSince = since
        state.interfaceName = link?.interfaceName ?? extended?.interfaceName
        state.dnsServers = extended?.dnsServers ?? []
        state.dnsSearchDomains = extended?.dnsSearchDomains ?? []
        let defaultRoute = await ports.interfaces.installsDefaultRoute(profile.id)
        state.isPrimaryInterface = (extended?.isPrimaryInterface ?? false) || defaultRoute
        state.takesOverDNS = await ports.interfaces.takesOverDNS(profile.id)

        guard let url = profile.checkURL else {
            tracker.forget(key: key)
            state.traffic = await ports.controller.statistics(of: profile.id)
            return state
        }
        // Failures while the tunnel settles count towards the grace too, so a
        // tunnel that never worked goes red as soon as it has settled.
        let result = tracker.confirm(key: key, result: await ports.checker.check(url, insecureTLS: profile.insecureTLS), now: ports.now())
        // Read after the check, so the counts include its own request.
        state.traffic = await ports.controller.statistics(of: profile.id)
        if !result.ok, ports.now().timeIntervalSince(since) < configuration.settleFor {
            state.state = .connecting
            state.transitionSince = state.transitionSince ?? since
        } else {
            state.checked = true
            state.result = result
        }
        return state
    }

    private func noteTransition(_ id: String, _ state: ConnectionState, now: Date) -> Date? {
        defer { lastState[id] = state }
        switch state {
        case .connecting, .disconnecting:
            if lastState[id] != state { transitionSince[id] = now }
            return transitionSince[id] ?? now
        default:
            transitionSince[id] = nil
            return nil
        }
    }

    // MARK: Actions

    /// Queues an action and looks again now and a little later. A failure to
    /// queue shows under the VPN in the menu.
    public func perform(_ action: VPNAction, on id: String) async {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let name = discovered.first(where: { $0.id == id })?.name
        actionErrors[id] = nil
        do {
            switch action {
            case .connect:
                note(try await ports.hooks.start(profile, name: name, controller: ports.controller), for: id)
            case .disconnect:
                handedOff[id] = nil
                try await ports.hooks.stop(profile, name: name, controller: ports.controller)
            case .reconnect:
                handedOff[id] = nil
                try await ports.hooks.stop(profile, name: name, controller: ports.controller)
                poke()
                await waitUntilDown(id)
                note(try await ports.hooks.start(profile, name: name, controller: ports.controller), for: id)
            }
        } catch {
            actionErrors[id] = "\(action.rawValue) failed: \(describe(error))"
        }
        poke()
        for delay in configuration.repollAfter {
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.poke()
            }
        }
    }

    /// Connects every shown profile that is not already up. Each runs on its
    /// own, so one waiting for a sign-in never holds up the rest.
    public func connectAll() async {
        var targets: [VPNProfile] = []
        for p in profiles {
            let status = await ports.controller.status(of: p.id)
            if status == nil || status == .disconnected || status == .invalid { targets.append(p) }
        }
        await withTaskGroup(of: Void.self) { group in
            for p in targets {
                group.addTask { await self.perform(.connect, on: p.id) }
            }
        }
    }

    /// Connects the profiles marked to connect at launch.
    public func autoConnect() async {
        var targets: [VPNProfile] = []
        for p in profiles where p.autoConnect {
            let status = await ports.controller.status(of: p.id)
            if status != .connected, status != .connecting { targets.append(p) }
        }
        await withTaskGroup(of: Void.self) { group in
            for p in targets {
                group.addTask { await self.perform(.connect, on: p.id) }
            }
        }
    }

    private func note(_ outcome: StartOutcome, for id: String) {
        switch outcome {
        case .started: handedOff[id] = nil
        case .handedToClient(let hint): handedOff[id] = (ports.now(), hint)
        }
    }

    private func waitUntilDown(_ id: String) async {
        let deadline = ContinuousClock.now + configuration.reconnectWait
        while ContinuousClock.now < deadline {
            let status = await ports.controller.status(of: id)
            if status == .disconnected || status == .invalid || status == nil { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func describe(_ error: any Error) -> String {
        if let e = error as? ActionError { return e.description }
        return (error as NSError).localizedDescription
    }
}
