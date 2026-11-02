import Foundation

/// What the system says about a live connection, beyond its status.
public struct ExtendedStatus: Equatable, Sendable {
    public var lastChange: Date?
    public var dnsServers: [String]
    public var dnsSearchDomains: [String]
    public var isPrimaryInterface: Bool
    public var interfaceName: String?

    public init(lastChange: Date? = nil, dnsServers: [String] = [], dnsSearchDomains: [String] = [], isPrimaryInterface: Bool = false, interfaceName: String? = nil) {
        self.lastChange = lastChange
        self.dnsServers = dnsServers
        self.dnsSearchDomains = dnsSearchDomains
        self.isPrimaryInterface = isPrimaryInterface
        self.interfaceName = interfaceName
    }
}

/// The tunnel interface behind a connected service.
public struct LinkInfo: Equatable, Sendable {
    public var interfaceName: String?
    public var addresses: [String]

    public init(interfaceName: String?, addresses: [String] = []) {
        self.interfaceName = interfaceName
        self.addresses = addresses
    }
}

/// Lists the VPN profiles the system knows.
public protocol ServiceDirectory: Sendable {
    func listVPNServices() async throws -> [DiscoveredService]
}

/// Asks the system about one VPN service and changes it.
public protocol ConnectionController: Sendable {
    func status(of serviceID: String) async -> RawConnectionStatus?
    func extendedStatus(of serviceID: String) async -> ExtendedStatus?
    func statistics(of serviceID: String) async -> Traffic?
    func start(_ serviceID: String) async throws
    func stop(_ serviceID: String) async throws
    /// Called with a service ID whenever its status may have changed.
    func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async
}

/// Maps services to their interfaces and tells how they affect routing and DNS.
public protocol InterfaceMap: Sendable {
    func link(for serviceID: String) async -> LinkInfo?
    func takesOverDNS(_ serviceID: String) async -> Bool
    func installsDefaultRoute(_ serviceID: String) async -> Bool
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async
}

/// One reachability check: DNS, then one GET.
public protocol ReachabilityChecker: Sendable {
    func check(_ url: URL, insecureTLS: Bool) async -> CheckResult
}

public protocol Notifier: Sendable {
    func send(_ notice: Notice) async
}

/// What a start did: the system is bringing the tunnel up, or the client's
/// own app has been asked to and the user has to finish there.
public enum StartOutcome: Equatable, Sendable {
    case started
    /// The client's window is up; `hint` says what to do there.
    case handedToClient(hint: String)
}

/// Starts and stops a profile the way its client needs. The default goes
/// through the controller; clients that need their own window get a fallback.
public protocol ProviderHooks: Sendable {
    func start(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws -> StartOutcome
    func stop(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws
}

public struct DefaultProviderHooks: ProviderHooks {
    public init() {}

    public func start(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws -> StartOutcome {
        try await controller.start(profile.id)
        return .started
    }

    public func stop(_ profile: VPNProfile, name: String?, controller: any ConnectionController) async throws {
        try await controller.stop(profile.id)
    }
}

public struct ActionError: Error, Equatable, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
