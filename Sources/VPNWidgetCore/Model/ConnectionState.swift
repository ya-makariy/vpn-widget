import Foundation

/// What SystemConfiguration says about a connection, free of its C types.
public enum RawConnectionStatus: Sendable, Equatable {
    case connected
    case connecting
    case disconnecting
    case disconnected
    case invalid
    /// The tunnel's own daemon gave up; the message says why.
    case failed
}

/// What a VPN is doing, from the system's connection status and whether its
/// profile still exists.
public enum ConnectionState: Hashable, Sendable {
    case connected
    case connecting
    case disconnecting
    case disconnected
    /// The system has the profile but cannot use it.
    case invalid
    /// The profile is gone: deleted in its client.
    case notFound
    /// The tunnel failed and is not retrying.
    case failed

    public var text: String {
        switch self {
        case .connected: "connected"
        case .connecting: "connecting"
        case .disconnecting: "disconnecting"
        case .disconnected: "disconnected"
        case .invalid: "invalid configuration"
        case .notFound: "profile removed in its client"
        case .failed: "failed"
        }
    }

    /// Which menu actions make sense.
    public var actions: Actions {
        switch self {
        case .disconnected, .invalid, .failed: Actions(connect: true)
        case .connected, .connecting: Actions(disconnect: true, reconnect: true)
        case .disconnecting, .notFound: Actions()
        }
    }
}

public struct Actions: Equatable, Sendable {
    public var connect: Bool
    public var disconnect: Bool
    public var reconnect: Bool

    public init(connect: Bool = false, disconnect: Bool = false, reconnect: Bool = false) {
        self.connect = connect
        self.disconnect = disconnect
        self.reconnect = reconnect
    }
}

public enum VPNAction: String, Sendable {
    case connect, disconnect, reconnect
}

public func deriveState(raw: RawConnectionStatus?, inDirectory: Bool) -> ConnectionState {
    guard inDirectory else { return .notFound }
    switch raw {
    case .connected: return .connected
    case .connecting: return .connecting
    case .disconnecting: return .disconnecting
    case .disconnected: return .disconnected
    case .failed: return .failed
    case .invalid, nil: return .invalid
    }
}
