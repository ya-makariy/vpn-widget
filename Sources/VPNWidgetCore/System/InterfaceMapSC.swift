import Foundation
import SystemConfiguration

/// Reads the dynamic store: which interface a service uses, and whether it has
/// taken the default route or all of DNS.
public final class InterfaceMapSC: InterfaceMap, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ya-makariy.vpn-widget.sc-store")
    private var store: SCDynamicStore?
    private var handler: (@Sendable () -> Void)?

    public init() {}

    public func setChangeHandler(_ handler: @escaping @Sendable () -> Void) async {
        queue.sync {
            self.handler = handler
            _ = self.openStore()
        }
    }

    public func link(for serviceID: String) async -> LinkInfo? {
        queue.sync {
            guard let v = value("State:/Network/Service/\(serviceID)/IPv4") else { return nil }
            return LinkInfo(interfaceName: v["InterfaceName"] as? String, addresses: v["Addresses"] as? [String] ?? [])
        }
    }

    /// The service's DNS servers answer every query: its DNS entry has no match
    /// domains and the system's resolver points at them.
    public func takesOverDNS(_ serviceID: String) async -> Bool {
        queue.sync {
            guard let dns = value("State:/Network/Service/\(serviceID)/DNS"),
                  let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty
            else { return false }
            if let match = dns["SupplementalMatchDomains"] as? [String], !match.isEmpty { return false }
            guard let global = value("State:/Network/Global/DNS"),
                  let globalServers = global["ServerAddresses"] as? [String]
            else { return false }
            return !Set(globalServers).isDisjoint(with: servers)
        }
    }

    public func installsDefaultRoute(_ serviceID: String) async -> Bool {
        queue.sync {
            guard let global = value("State:/Network/Global/IPv4") else { return false }
            return global["PrimaryService"] as? String == serviceID
        }
    }

    // MARK: Store (on queue)

    private func value(_ key: String) -> [String: Any]? {
        guard let store = openStore() else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    private func openStore() -> SCDynamicStore? {
        if let store { return store }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callout: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<InterfaceMapSC>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let store = SCDynamicStoreCreate(nil, "VPN Widget" as CFString, callout, &context) else { return nil }
        let patterns = [
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Service/.*/DNS",
            "State:/Network/Global/IPv4",
            "State:/Network/Global/DNS",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, nil, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
        return store
    }

    private func changed() {
        handler?()
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}
