import SwiftUI
import VPNWidgetCore

/// Domains to resolve through the tunnel's DNS servers, written to
/// `/etc/resolver` with an administrator's approval.
struct SplitDNSSectionView: View {
    @Environment(AppModel.self) private var model
    @Binding var profile: VPNProfile
    @State private var installing = false

    private var row: ProfileRowState? { model.rows.first { $0.id == profile.id } }
    private var canFill: Bool { row.map { !$0.dnsServers.isEmpty || !$0.dnsSearchDomains.isEmpty } ?? false }

    var body: some View {
        Section {
            EditableStringList(title: "Domains", placeholder: "corp.example", items: $profile.dnsDomains, validate: { ResolverFiles.normalizeDomain($0) != nil })
            EditableStringList(title: "DNS servers", placeholder: "10.0.0.53", items: $profile.dnsServers, validate: ResolverFiles.isServer)
            HStack {
                Button("Fill from Current Connection") { model.fillDNS(from: profile.id) }
                    .disabled(!canFill)
                Spacer()
                statusLabel
            }
            HStack {
                Button("Install Resolver Files…") {
                    installing = true
                    model.installResolverFiles()
                    installing = false
                }
                .disabled(installing || model.renderedResolverFiles.isEmpty)
                Button("Remove All") { model.removeResolverFiles() }
                    .disabled(installing || model.config.managedResolverDomains.isEmpty)
                if installing { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Split DNS")
        } footer: {
            Text("macOS sends queries for these domains to these servers, whichever VPN is primary, through files in /etc/resolver. Installing covers the domains of every shown profile at once and asks for an administrator password. Check with: scutil --dns")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.resolverStatus(for: profile) {
        case .installed:
            Label("Resolver files installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .outOfDate:
            Label("Resolver files out of date", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .foreign:
            Label("A resolver file exists that VPN Widget did not write", systemImage: "hand.raised.fill").foregroundStyle(.orange)
        case .notInstalled:
            Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case nil:
            Text("Add domains and servers to enable").foregroundStyle(.secondary)
        }
    }
}
