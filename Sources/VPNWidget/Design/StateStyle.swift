import SwiftUI
import VPNWidgetCore

/// Colours and symbols per state: the one place they are decided.
enum StateStyle {
    static func color(_ phase: ConnectionPhase) -> Color {
        switch phase {
        case .connected: .green
        case .rechecking: .yellow
        case .connectedNotAnswering, .failed: .red
        case .connecting, .waitingForSignIn, .disconnecting: .blue
        case .disconnected, .removed: .secondary
        }
    }

    /// A faint tint for the row's glass. Nil leaves it clear.
    static func tint(_ phase: ConnectionPhase) -> Color? {
        switch phase {
        case .connected: .green.opacity(0.16)
        case .rechecking: .yellow.opacity(0.18)
        case .connectedNotAnswering, .failed: .red.opacity(0.2)
        case .connecting, .waitingForSignIn, .disconnecting: .blue.opacity(0.14)
        case .disconnected, .removed: nil
        }
    }

    static func symbol(_ kind: ProviderKind) -> String {
        switch kind {
        case .forticlient: "shield.lefthalf.filled"
        case .anyconnect: "network"
        case .amneziawg: "bolt.horizontal.fill"
        case .wireguard: "bolt.horizontal"
        case .openfortivpn: "terminal"
        case .openconnect: "terminal"
        case .other: "point.3.connected.trianglepath.dotted"
        }
    }

    static func color(_ aggregate: AggregateState) -> Color {
        switch aggregate {
        case .allConnected: .green
        case .partial: .green
        case .allStopped, .empty: .secondary
        case .transitioning: .blue
        case .rechecking: .yellow
        case .attention: .red
        }
    }
}
