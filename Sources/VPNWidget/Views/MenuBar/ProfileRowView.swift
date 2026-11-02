import SwiftUI
import VPNWidgetCore

/// One VPN in the panel: name and state, the action, and the details while up.
struct ProfileRowView: View {
    @Environment(AppModel.self) private var model
    var row: ProfileRowState
    var namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ClientKindBadge(kind: row.kind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    stateLine
                }
                Spacer(minLength: 6)
                actions
            }
            if row.phase.isUp {
                ProfileDetailsView(row: row)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let error = row.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Retry") { model.reconnect(row.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
                .font(.caption2)
            }
            if row.phase == .waitingForSignIn {
                HStack(spacing: 6) {
                    Text(row.clientHint ?? "Finish signing in in \(row.kind.displayName).")
                    if row.signInURL != nil {
                        Spacer()
                        Button("Open page") { model.openSignInPage(row.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: Metrics.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowGlass(tint: StateStyle.tint(row.phase), id: row.id, in: namespace)
        .animation(.snappy, value: row.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayName), \(row.phase.label)")
    }

    private var stateLine: some View {
        HStack(spacing: 5) {
            if row.phase.isTransitioning {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(StateStyle.color(row.phase)).frame(width: 7, height: 7)
            }
            Text(row.phase.label)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var actions: some View {
        let busy = model.busy.contains(row.id)
        HStack(spacing: 4) {
            if row.phase.canDisconnect {
                Button("Disconnect") { model.disconnect(row.id) }
                    .buttonStyle(.glass)
                    .disabled(busy)
                Menu {
                    Button("Reconnect") { model.reconnect(row.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            } else if row.phase.canConnect {
                Button("Connect") { model.connect(row.id) }
                    .buttonStyle(.glassProminent)
                    .disabled(busy)
            }
        }
        .controlSize(.small)
    }
}

/// Traffic, reachability and the interface, while the tunnel is up.
struct ProfileDetailsView: View {
    var row: ProfileRowState

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                if let t = row.traffic {
                    Label(Format.bytes(t.bytesIn), systemImage: "arrow.down")
                    Label(Format.bytes(t.bytesOut), systemImage: "arrow.up")
                } else {
                    Text("No traffic counters").gridCellColumns(2)
                }
            }
            if row.hasCheck {
                GridRow {
                    checkLine.gridCellColumns(2)
                }
            }
            if row.interfaceName != nil || row.connectedSince != nil {
                GridRow {
                    if let since = row.connectedSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Label("up \(Format.uptime(since: since, now: context.date))", systemImage: "clock")
                        }
                    }
                    if let name = row.interfaceName {
                        Label(name, systemImage: "cable.connector")
                    }
                }
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.leading, 34)
    }

    @ViewBuilder
    private var checkLine: some View {
        switch row.phase {
        case .connectedNotAnswering:
            Label(row.checkDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .rechecking:
            Label(row.checkDescription, systemImage: "arrow.trianglehead.2.clockwise")
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .foregroundStyle(.orange)
        default:
            if let status = row.httpStatus {
                Label("HTTP \(status) · \(Format.milliseconds(row.latencyMS)) / \(Format.milliseconds(row.totalMS))", systemImage: "checkmark.circle")
            } else {
                Label("Checking…", systemImage: "ellipsis.circle")
            }
        }
    }
}
