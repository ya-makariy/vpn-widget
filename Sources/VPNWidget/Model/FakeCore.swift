import Foundation
import VPNWidgetCore

/// A pretend system for screenshots and UI work: `VPNWIDGET_FAKE=1`. Four
/// profiles that connect and disconnect on command, one of which starts
/// failing its check a little while after it comes up.
actor FakeSystem: ServiceDirectory, ConnectionController, InterfaceMap, ReachabilityChecker {
    static let profiles: [VPNProfile] = [
        VPNProfile(id: "fake-forti", displayName: "Office", providerKind: .forticlient, checkURL: URL(string: "https://wiki.office.example/"), insecureTLS: true, autoConnect: true, dnsDomains: ["office.example"], dnsServers: ["10.10.0.53"]),
        VPNProfile(id: "fake-awg", displayName: "Lab", providerKind: .amneziawg, checkURL: URL(string: "https://grafana.lab.example/login")),
        VPNProfile(id: "fake-wg", displayName: "Home server", providerKind: .wireguard),
        VPNProfile(id: "fake-ac", displayName: "Partner", providerKind: .anyconnect, checkURL: URL(string: "https://portal.partner.example/")),
    ]

    private var statuses: [String: RawConnectionStatus] = ["fake-forti": .connected, "fake-awg": .disconnected, "fake-wg": .connected, "fake-ac": .disconnected]
    private var since: [String: Date] = ["fake-forti": Date().addingTimeInterval(-4000), "fake-wg": Date().addingTimeInterval(-300)]
    private var traffic: [String: Traffic] = ["fake-forti": Traffic(bytesIn: 310_000_000, bytesOut: 12_400_000), "fake-wg": Traffic(bytesIn: 4_200_000, bytesOut: 900_000)]
    private var handler: (@Sendable (String) -> Void)?
    private var storeHandler: (@Sendable () -> Void)?

    func listVPNServices() async throws -> [DiscoveredService] {
        Self.profiles.map { DiscoveredService(id: $0.id, name: $0.displayName, enabled: true, providerBundleID: Self.bundleID($0.providerKind)) }
            + [
                DiscoveredService(id: "fake-other-1", name: "Travel proxy", enabled: true, providerBundleID: "io.example.proxy"),
                DiscoveredService(id: "fake-old", name: "Old office (IPsec)", enabled: false, providerBundleID: "com.cisco.anyconnect.networkextension"),
            ]
    }

    static func bundleID(_ kind: ProviderKind) -> String? {
        switch kind {
        case .forticlient: "com.fortinet.forticlient.macos.vpn.nwextension"
        case .anyconnect: "com.cisco.anyconnect.networkextension"
        case .amneziawg: "org.amnezia.awg.network-extension"
        case .wireguard: "com.wireguard.macos.network-extension"
        case .other: nil
        }
    }

    func status(of serviceID: String) async -> RawConnectionStatus? {
        statuses[serviceID] ?? (serviceID == "fake-old" ? .invalid : .disconnected)
    }

    func extendedStatus(of serviceID: String) async -> ExtendedStatus? {
        guard statuses[serviceID] == .connected else { return nil }
        let dns = serviceID == "fake-forti" ? ExtendedStatus(lastChange: since[serviceID], dnsServers: ["10.10.0.53", "10.10.0.54"], dnsSearchDomains: ["office.example", "corp.office.example"], interfaceName: "utun5") : ExtendedStatus(lastChange: since[serviceID], interfaceName: "utun6")
        return dns
    }

    func statistics(of serviceID: String) async -> Traffic? {
        guard statuses[serviceID] == .connected, var t = traffic[serviceID] else { return nil }
        t.bytesIn += UInt64.random(in: 1_000...80_000)
        t.bytesOut += UInt64.random(in: 100...9_000)
        traffic[serviceID] = t
        return t
    }

    func start(_ serviceID: String) async throws {
        if serviceID == "fake-old" { throw ActionError("the system refused to start it: invalid configuration") }
        statuses[serviceID] = .connecting
        handler?(serviceID)
        let delay: Duration = serviceID == "fake-ac" || serviceID == "fake-forti" ? .seconds(9) : .seconds(2)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.finishConnecting(serviceID)
        }
    }

    private func finishConnecting(_ serviceID: String) {
        guard statuses[serviceID] == .connecting else { return }
        statuses[serviceID] = .connected
        since[serviceID] = Date()
        traffic[serviceID] = Traffic(bytesIn: 0, bytesOut: 0)
        handler?(serviceID)
        storeHandler?()
    }

    func stop(_ serviceID: String) async throws {
        statuses[serviceID] = .disconnecting
        handler?(serviceID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.finishDisconnecting(serviceID)
        }
    }

    private func finishDisconnecting(_ serviceID: String) {
        statuses[serviceID] = .disconnected
        since[serviceID] = nil
        traffic[serviceID] = nil
        handler?(serviceID)
        storeHandler?()
    }

    func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async { self.handler = handler }
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async { storeHandler = handler }

    func link(for serviceID: String) async -> LinkInfo? {
        statuses[serviceID] == .connected ? LinkInfo(interfaceName: serviceID == "fake-forti" ? "utun5" : "utun6", addresses: ["10.99.0.2"]) : nil
    }

    func takesOverDNS(_ serviceID: String) async -> Bool { serviceID == "fake-forti" && statuses[serviceID] == .connected }
    func installsDefaultRoute(_ serviceID: String) async -> Bool { false }

    func check(_ url: URL, insecureTLS: Bool) async -> CheckResult {
        try? await Task.sleep(for: .milliseconds(Int.random(in: 30...200)))
        // The lab tunnel's service stops answering 25 s after the tunnel came up.
        if url.host == "grafana.lab.example", let s = since["fake-awg"], Date().timeIntervalSince(s) > 25 {
            return CheckResult(dns: "ok", http: "timeout")
        }
        return CheckResult(dns: "ok", http: url.host == "wiki.office.example" ? "HTTP 401" : "HTTP 200", dnsMS: 2, connectMS: Int.random(in: 8...40), totalMS: Int.random(in: 60...220), httpStatus: url.host == "wiki.office.example" ? 401 : 200, ok: true)
    }
}
