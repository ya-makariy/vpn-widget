import Foundation
import VPNWidgetCore

/// What a row in the panel is doing, in the words the user sees.
enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case waitingForSignIn
    case disconnecting
    case connected
    case connectedNotAnswering
    case rechecking
    case failed(String)
    case removed

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .waitingForSignIn: "Waiting for sign-in…"
        case .disconnecting: "Disconnecting…"
        case .connected: "Connected"
        case .connectedNotAnswering: "Connected, service not answering"
        case .rechecking: "Connected, rechecking…"
        case .failed(let why): why
        case .removed: "Profile removed in its client"
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .connecting, .waitingForSignIn, .disconnecting: true
        default: false
        }
    }

    var isUp: Bool {
        switch self {
        case .connected, .connectedNotAnswering, .rechecking: true
        default: false
        }
    }

    var canDisconnect: Bool { isUp || self == .connecting || self == .waitingForSignIn }
    var canConnect: Bool {
        switch self {
        case .disconnected, .failed: true
        default: false
        }
    }
}

/// One profile as the panel shows it. Built from a core `ProfileState`; the
/// views never see SystemConfiguration types.
struct ProfileRowState: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var kind: ProviderKind
    var phase: ConnectionPhase
    var connectedSince: Date?
    var traffic: Traffic?
    var hasCheck: Bool
    var httpStatus: Int?
    var latencyMS: Int
    var totalMS: Int
    var checkDescription: String
    var interfaceName: String?
    var lastError: String?
    var takesOverDNS: Bool
    var isPrimaryInterface: Bool
    var dnsServers: [String]
    var dnsSearchDomains: [String]

    /// How long a sign-in client may sit in "connecting" before the row says
    /// it is waiting for the user.
    static let signInAfter: TimeInterval = 5

    init(_ p: ProfileState, now: Date) {
        id = p.id
        displayName = p.profile.displayName
        kind = p.profile.providerKind
        connectedSince = p.connectedSince
        traffic = p.traffic
        hasCheck = p.profile.checkURL != nil
        httpStatus = p.checked ? p.result.httpStatus : nil
        latencyMS = p.checked ? p.result.connectMS : 0
        totalMS = p.checked ? p.result.totalMS : 0
        checkDescription = p.checked ? p.result.description : ""
        interfaceName = p.interfaceName
        lastError = p.lastActionError
        takesOverDNS = p.takesOverDNS
        isPrimaryInterface = p.isPrimaryInterface
        dnsServers = p.dnsServers
        dnsSearchDomains = p.dnsSearchDomains
        switch p.state {
        case .connected:
            if p.checked, p.result.failed { phase = .connectedNotAnswering }
            else if p.checked, p.result.doubtful { phase = .rechecking }
            else { phase = .connected }
        case .connecting:
            let waited = p.transitionSince.map { now.timeIntervalSince($0) } ?? 0
            phase = p.profile.providerKind.signsInInteractively && waited >= Self.signInAfter ? .waitingForSignIn : .connecting
        case .disconnecting: phase = .disconnecting
        case .disconnected: phase = .disconnected
        case .invalid: phase = .failed("Invalid configuration")
        case .notFound: phase = .removed
        }
    }
}

/// The icon's summary of every shown profile.
enum AggregateState: Equatable, Sendable {
    case empty
    case allStopped
    case partial
    case allConnected
    case transitioning
    case rechecking
    case attention

    init(snapshot: Snapshot) {
        if snapshot.profiles.isEmpty {
            self = .empty
            return
        }
        switch snapshot.level {
        case .problem: self = .attention
        case .progress: self = .transitioning
        case .ok: self = snapshot.doubtful ? .rechecking : .allConnected
        case .partial: self = snapshot.doubtful ? .rechecking : .partial
        case .off: self = .allStopped
        }
    }

    var animates: Bool { self == .transitioning || self == .attention }
}
