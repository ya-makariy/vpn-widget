import SwiftUI
import VPNWidgetCore

/// The profiles the system knows on the left, grouped by client; the chosen
/// one's settings on the right.
struct ProfilesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(model.config.profiles) { profile in
                        shownRow(profile)
                    }
                    .onMove { model.moveProfiles(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Shown in the panel")
                } footer: {
                    if model.config.profiles.isEmpty {
                        Text("Turn on a profile below to show it.")
                    } else {
                        Text("Drag to reorder.")
                    }
                }
                ForEach(groupedHidden, id: \.kind) { group in
                    Section(group.kind.displayName) {
                        ForEach(group.services) { service in
                            hiddenRow(service)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = model.config.profiles.first?.id }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let profile = model.profile(id) {
            ProfileEditorView(profile: profile)
                .id(id)
        } else if let id = selection, let service = model.discovered.first(where: { $0.id == id }) {
            ContentUnavailableView {
                Label(service.name, systemImage: StateStyle.symbol(service.kind))
            } description: {
                Text("This \(service.kind.displayName) profile is not shown in the panel.")
            } actions: {
                Button("Show in Panel") { model.setShown(service, true) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("Select a profile", systemImage: "lock.shield", description: Text("Profiles come from FortiClient, AnyConnect, AmneziaWG, WireGuard and other VPN apps. Create or import them there; choose here which to show."))
        }
    }

    private struct Group {
        var kind: ProviderKind
        var services: [DiscoveredService]
    }

    private var groupedHidden: [Group] {
        let hidden = model.discovered.filter { !model.isShown($0.id) }
        return ProviderKind.allCases.compactMap { kind in
            let services = hidden.filter { $0.kind == kind }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return services.isEmpty ? nil : Group(kind: kind, services: services)
        }
    }

    private func shownRow(_ profile: VPNProfile) -> some View {
        HStack(spacing: 8) {
            ClientKindBadge(kind: profile.providerKind, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).lineLimit(1)
                if let row = model.rows.first(where: { $0.id == profile.id }) {
                    Text(row.phase.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("Shown", isOn: Binding(
                get: { true },
                set: { _ in
                    if let service = model.discovered.first(where: { $0.id == profile.id }) {
                        model.setShown(service, false)
                    } else {
                        model.setShown(DiscoveredService(id: profile.id, name: profile.displayName, enabled: true, providerBundleID: nil), false)
                    }
                    if selection == profile.id { selection = nil }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .tag(profile.id)
    }

    private func hiddenRow(_ service: DiscoveredService) -> some View {
        HStack(spacing: 8) {
            ClientKindBadge(kind: service.kind, size: 20)
            Text(service.name)
                .lineLimit(1)
                .foregroundStyle(service.enabled ? .primary : .secondary)
            Spacer()
            Toggle("Shown", isOn: Binding(get: { false }, set: { on in
                model.setShown(service, on)
                if on { selection = service.id }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .tag(service.id)
    }
}
