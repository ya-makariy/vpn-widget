import Foundation
import SystemConfiguration

/// Talks to the system about VPN services. Each service gets two
/// `SCNetworkConnection`s: one that is never scheduled, so that its status
/// calls ask the system every time, and one scheduled on the queue only for
/// change callbacks. A scheduled connection answers status calls from a cache
/// that is empty until its first callback, which is why queries never use it.
public final class ConnectionControllerSC: ConnectionController, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ya-makariy.vpn-widget.sc-connection")
    private var queries: [String: SCNetworkConnection] = [:]
    private var watchers: [String: SCNetworkConnection] = [:]
    private var handler: (@Sendable (String) -> Void)?

    public init() {}

    public func setChangeHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        queue.sync { self.handler = handler }
    }

    public func status(of serviceID: String) async -> RawConnectionStatus? {
        queue.sync {
            guard let conn = query(serviceID) else { return nil }
            let status = Self.map(SCNetworkConnectionGetStatus(conn))
            if status == .invalid {
                // Forget it, so that a profile recreated under the same ID is picked up.
                drop(serviceID)
            }
            return status
        }
    }

    public func extendedStatus(of serviceID: String) async -> ExtendedStatus? {
        queue.sync {
            guard let conn = query(serviceID),
                  let dict = SCNetworkConnectionCopyExtendedStatus(conn) as? [String: Any]
            else { return nil }
            let ipv4 = dict["IPv4"] as? [String: Any]
            return ExtendedStatus(
                lastChange: dict["LastStatusChangeTime"] as? Date,
                dnsServers: dict["DNSServers"] as? [String] ?? [],
                dnsSearchDomains: dict["DNSSearchDomains"] as? [String] ?? [],
                isPrimaryInterface: (dict["IsPrimaryInterface"] as? NSNumber)?.boolValue ?? false,
                interfaceName: ipv4?["InterfaceName"] as? String
            )
        }
    }

    public func statistics(of serviceID: String) async -> Traffic? {
        queue.sync {
            guard let conn = query(serviceID),
                  let dict = SCNetworkConnectionCopyStatistics(conn) as? [String: Any],
                  let vpn = dict["VPN"] as? [String: Any],
                  let bytesIn = (vpn["BytesIn"] as? NSNumber)?.uint64Value,
                  let bytesOut = (vpn["BytesOut"] as? NSNumber)?.uint64Value
            else { return nil }
            return Traffic(bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }

    public func start(_ serviceID: String) async throws {
        try queue.sync {
            guard let conn = query(serviceID) else { throw ActionError("no such VPN service") }
            guard SCNetworkConnectionStart(conn, nil, true) else {
                throw ActionError("the system refused to start it: \(scErrorText())")
            }
        }
    }

    public func stop(_ serviceID: String) async throws {
        try queue.sync {
            guard let conn = query(serviceID) else { throw ActionError("no such VPN service") }
            guard SCNetworkConnectionStop(conn, true) else {
                throw ActionError("the system refused to stop it: \(scErrorText())")
            }
        }
    }

    // MARK: Connections (on queue)

    private final class Box {
        let serviceID: String
        weak var owner: ConnectionControllerSC?
        init(serviceID: String, owner: ConnectionControllerSC) {
            self.serviceID = serviceID
            self.owner = owner
        }
    }

    /// The unscheduled connection for queries and actions. Creating it also
    /// arms the watcher, so that changes to any service once asked about are
    /// reported.
    private func query(_ serviceID: String) -> SCNetworkConnection? {
        if let conn = queries[serviceID] { return conn }
        guard let conn = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil) else { return nil }
        queries[serviceID] = conn
        watch(serviceID)
        return conn
    }

    private func watch(_ serviceID: String) {
        guard watchers[serviceID] == nil else { return }
        let box = Box(serviceID: serviceID, owner: self)
        var context = SCNetworkConnectionContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in Unmanaged<Box>.fromOpaque(info).release() },
            copyDescription: nil
        )
        let callout: SCNetworkConnectionCallBack = { _, _, info in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            box.owner?.changed(box.serviceID)
        }
        guard let conn = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, callout, &context) else {
            Unmanaged.passUnretained(box).release()
            return
        }
        // Read once before scheduling, so that the connection has a status to
        // report changes against.
        _ = SCNetworkConnectionGetStatus(conn)
        SCNetworkConnectionSetDispatchQueue(conn, queue)
        watchers[serviceID] = conn
    }

    private func drop(_ serviceID: String) {
        queries[serviceID] = nil
        if let conn = watchers.removeValue(forKey: serviceID) {
            SCNetworkConnectionSetDispatchQueue(conn, nil)
        }
    }

    /// Runs on the queue, from the callback.
    private func changed(_ serviceID: String) {
        handler?(serviceID)
    }

    static func map(_ status: SCNetworkConnectionStatus) -> RawConnectionStatus {
        switch status {
        case .connected: .connected
        case .connecting: .connecting
        case .disconnecting: .disconnecting
        case .disconnected: .disconnected
        case .invalid: .invalid
        @unknown default: .invalid
        }
    }
}
