import Foundation
@testable import VPNWidgetCore

/// A clock the tests move by hand.
final class FakeNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    var closure: @Sendable () -> Date { { [self] in now } }
}

actor FakeDirectory: ServiceDirectory {
    var services: [DiscoveredService]
    var error: (any Error)?
    init(_ services: [DiscoveredService]) { self.services = services }
    func set(_ services: [DiscoveredService]) { self.services = services }
    func fail(_ error: (any Error)?) { self.error = error }
    func listVPNServices() async throws -> [DiscoveredService] {
        if let error { throw error }
        return services
    }
}

actor FakeController: ConnectionController {
    var statuses: [String: RawConnectionStatus]
    var extended: [String: ExtendedStatus] = [:]
    var stats: [String: Traffic] = [:]
    var startError: (any Error)?
    private(set) var started: [String] = []
    private(set) var stopped: [String] = []
    private var handler: (@Sendable (String) -> Void)?

    init(_ statuses: [String: RawConnectionStatus]) { self.statuses = statuses }

    func set(_ id: String, _ status: RawConnectionStatus?) { statuses[id] = status }
    func setExtended(_ id: String, _ e: ExtendedStatus?) { extended[id] = e }
    func setStats(_ id: String, _ t: Traffic?) { stats[id] = t }
    func failStart(_ error: (any Error)?) { startError = error }
    func fire(_ id: String) { handler?(id) }

    func status(of serviceID: String) async -> RawConnectionStatus? { statuses[serviceID] }
    func extendedStatus(of serviceID: String) async -> ExtendedStatus? { extended[serviceID] }
    func statistics(of serviceID: String) async -> Traffic? { stats[serviceID] }
    func start(_ serviceID: String) async throws {
        if let startError { throw startError }
        started.append(serviceID)
        statuses[serviceID] = .connecting
    }
    func stop(_ serviceID: String) async throws {
        stopped.append(serviceID)
        statuses[serviceID] = .disconnected
    }
    func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async { self.handler = handler }
}

actor FakeInterfaces: InterfaceMap {
    var links: [String: LinkInfo] = [:]
    var dnsTakers: Set<String> = []
    var primaries: Set<String> = []
    func setLink(_ id: String, _ link: LinkInfo?) { links[id] = link }
    func setTakesOverDNS(_ id: String, _ on: Bool) { if on { dnsTakers.insert(id) } else { dnsTakers.remove(id) } }
    func setPrimary(_ id: String, _ on: Bool) { if on { primaries.insert(id) } else { primaries.remove(id) } }
    func link(for serviceID: String) async -> LinkInfo? { links[serviceID] }
    func takesOverDNS(_ serviceID: String) async -> Bool { dnsTakers.contains(serviceID) }
    func installsDefaultRoute(_ serviceID: String) async -> Bool { primaries.contains(serviceID) }
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
}

actor FakeChecker: ReachabilityChecker {
    var results: [String: CheckResult] = [:]
    private(set) var calls = 0
    func set(_ host: String, _ result: CheckResult) { results[host] = result }
    func check(_ url: URL, insecureTLS: Bool) async -> CheckResult {
        calls += 1
        return results[url.host ?? ""] ?? CheckResult(dns: "ok", http: "HTTP 200", connectMS: 5, totalMS: 20, httpStatus: 200, ok: true)
    }
}

actor FakeNotifier: Notifier {
    private(set) var notices: [Notice] = []
    func send(_ notice: Notice) async { notices.append(notice) }
}

/// A bundle of fakes wired into an engine.
struct Rig {
    let now = FakeNow()
    let directory: FakeDirectory
    let controller: FakeController
    let interfaces = FakeInterfaces()
    let checker = FakeChecker()
    let notifier = FakeNotifier()
    let engine: PollEngine

    static let ok = CheckResult(dns: "ok", http: "HTTP 200", connectMS: 5, totalMS: 20, httpStatus: 200, ok: true)
    static let down = CheckResult(dns: "ok", http: "timeout")

    init(profiles: [VPNProfile], statuses: [String: RawConnectionStatus], hooks: any ProviderHooks = DefaultProviderHooks(), configure: (inout PollEngine.Configuration) -> Void = { _ in }) {
        directory = FakeDirectory(profiles.map { DiscoveredService(id: $0.id, name: $0.displayName, enabled: true, providerBundleID: nil) })
        controller = FakeController(statuses)
        var config = PollEngine.Configuration()
        configure(&config)
        engine = PollEngine(
            profiles: profiles,
            ports: PollEngine.Ports(directory: directory, controller: controller, interfaces: interfaces, checker: checker, notifier: notifier, hooks: hooks, now: now.closure),
            configuration: config
        )
    }
}

extension VPNProfile {
    static func test(_ id: String, kind: ProviderKind = .wireguard, check: String? = "https://\(UUID().uuidString.lowercased()).example/") -> VPNProfile {
        VPNProfile(id: id, displayName: id.capitalized, providerKind: kind, checkURL: check.flatMap(URL.init(string:)))
    }
}

/// Hooks that hand every start to the client's window.
struct HandoffHooks: ProviderHooks {
    func start(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws -> StartOutcome {
        .handedToClient(hint: "Click Connect in the client")
    }
    func stop(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws {
        try await controller.stop(profile.id)
    }
}
