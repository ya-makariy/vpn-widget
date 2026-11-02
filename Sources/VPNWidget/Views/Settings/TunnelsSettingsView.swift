import SwiftUI
import VPNWidgetCore

/// Tunnels the widget runs itself: setting up once, then adding, changing and
/// removing them. Each change goes through the administrator prompt.
struct TunnelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: VPNProfile?
    @State private var adding: TunnelConfig.Kind?

    var body: some View {
        Form {
            setupSection
            Section {
                if model.ownTunnels.isEmpty {
                    Text("No tunnels yet.").foregroundStyle(.secondary)
                }
                ForEach(model.ownTunnels) { profile in
                    HStack(spacing: 10) {
                        ClientKindBadge(kind: profile.providerKind, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                            if let t = profile.tunnel {
                                Text(verbatim: "\(t.kind.displayName) · \(t.host):\(String(t.port))\(t.saml ? " · SAML" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let row = model.rows.first(where: { $0.id == profile.id }) {
                            Text(row.phase.label).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.tunnelNeedsApply(profile) {
                            Label("Changes not applied", systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Edit…") { editing = profile }
                        Button("Remove…", role: .destructive) { model.removeTunnel(profile.id) }
                    }
                    .controlSize(.small)
                }
            } header: {
                HStack {
                    Text("Tunnels")
                    Spacer()
                    Menu("Add Tunnel") {
                        ForEach(TunnelConfig.Kind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { adding = kind }
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.tunnelSetupStatus == .notSetUp)
                }
            } footer: {
                Text("A tunnel is a launchd job on this Mac that runs openfortivpn or openconnect as root. The widget starts and stops it without a password through a sudoers rule limited to these jobs. Connecting needs no other app: a SAML sign-in opens in the browser.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // VPNWIDGET_PREVIEW=settings:tunnels:add opens the form, for screenshots.
            if ProcessInfo.processInfo.environment["VPNWIDGET_PREVIEW"]?.hasSuffix(":add") == true { adding = .openfortivpn }
        }
        .sheet(item: $adding) { kind in
            TunnelEditorView(profile: VPNProfile(tunnel: TunnelConfig(name: "", kind: kind, host: "", port: kind == .openfortivpn ? 8443 : 443, saml: kind == .openfortivpn), displayName: ""), isNew: true)
                .environment(model)
        }
        .sheet(item: $editing) { profile in
            TunnelEditorView(profile: profile, isNew: false)
                .environment(model)
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        let status = model.tunnelSetupStatus
        let missing = model.missingTunnelTools
        Section {
            HStack {
                switch status {
                case .ready:
                    Label("Set up", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .outdated:
                    Label("Helper out of date", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .notSetUp:
                    Label("Not set up", systemImage: "circle.dashed").foregroundStyle(.secondary)
                }
                Spacer()
                Button(status == .notSetUp ? "Set Up Tunnels…" : "Set Up Again…") { model.setUpTunnels() }
                    .disabled(!missing.isEmpty && status == .notSetUp)
            }
            if !missing.isEmpty {
                Label("Install the tools first: brew install \(missing.joined(separator: " "))", systemImage: "terminal")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Setup")
        } footer: {
            Text("Setup asks for an administrator password once. It copies the helper and the tools to /usr/local/libexec/vpn-widget (root-owned, so that the passwordless start never runs a file you can edit) and writes /etc/sudoers.d/vpn-widget for your user. Run it again after updating the app.")
        }
    }
}

extension TunnelConfig.Kind: Identifiable {
    public var id: String { rawValue }
}

/// The form for one tunnel. Saving installs it through the admin prompt.
struct TunnelEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: VPNProfile
    let isNew: Bool
    @State private var password = ""
    @State private var nameEdited = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var domainsText: String
    @State private var serversText: String

    init(profile: VPNProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        _domainsText = State(initialValue: profile.dnsDomains.joined(separator: " "))
        _serversText = State(initialValue: profile.dnsServers.joined(separator: " "))
    }

    private var tunnel: Binding<TunnelConfig> {
        Binding(get: { profile.tunnel ?? TunnelConfig(name: "", kind: .openfortivpn, host: "", port: 8443) }, set: { profile.tunnel = $0 })
    }

    private var kind: TunnelConfig.Kind { profile.tunnel?.kind ?? .openfortivpn }

    private var canSave: Bool {
        guard let t = profile.tunnel else { return false }
        return TunnelConfig.isValidName(t.name) && TunnelConfig.parseGateway(t.host) != nil && (1...65535).contains(t.port) && !profile.displayName.isEmpty
            && (kind != .openconnect || !(t.username ?? "").isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(kind.displayName) {
                    TextField("Name in the panel", text: $profile.displayName)
                        .onChange(of: profile.displayName) { _, new in
                            if isNew, !nameEdited { tunnel.wrappedValue.name = TunnelConfig.suggestName(from: new) }
                        }
                    TextField("Tunnel name", text: tunnel.name, prompt: Text("letters, digits, dashes"))
                        .disabled(!isNew)
                        .onChange(of: tunnel.wrappedValue.name) { _, _ in if isNew { nameEdited = true } }
                        .font(.body.monospaced())
                    TextField("Gateway host", text: tunnel.host, prompt: Text("vpn.example.com"))
                        .autocorrectionDisabled()
                        .onSubmit(normalizeGateway)
                    if let parts = TunnelConfig.parseGateway(tunnel.wrappedValue.host), parts.host != tunnel.wrappedValue.host || parts.port != nil || parts.realm != nil {
                        Text("Will use host \(parts.host)\(parts.port.map { ", port \($0)" } ?? "")\(parts.realm.map { ", realm \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Port", value: tunnel.port, format: .number.grouping(.never))
                }
                if kind == .openfortivpn {
                    Section("Sign-in") {
                        Toggle("SAML in the browser", isOn: tunnel.saml)
                        TextField("Realm", text: optional(tunnel.realm), prompt: Text("sso"))
                        if !tunnel.wrappedValue.saml {
                            TextField("Username", text: optional(tunnel.username))
                            SecureField("Password", text: $password, prompt: Text(tunnel.wrappedValue.hasSecret ? "stored; type to replace" : ""))
                        }
                        TextField("Trusted certificate digest", text: optional(tunnel.trustedCert), prompt: Text("sha256 hex, for a self-signed gateway"))
                            .font(.body.monospaced())
                    }
                } else {
                    Section("Sign-in") {
                        TextField("Username", text: optional(tunnel.username))
                        SecureField("Password", text: $password, prompt: Text(tunnel.wrappedValue.hasSecret ? "stored; type to replace" : ""))
                        TextField("Auth group", text: optional(tunnel.realm), prompt: Text("optional"))
                        TextField("Server certificate pin", text: optional(tunnel.trustedCert), prompt: Text("pin-sha256:…, optional"))
                            .font(.body.monospaced())
                        TextField("Protocol", text: optional(tunnel.protocolName), prompt: Text("anyconnect"))
                    }
                }
                Section {
                    TextField("Domains", text: $domainsText, prompt: Text("corp.example lab.example"))
                        .autocorrectionDisabled()
                    TextField("DNS servers", text: $serversText, prompt: Text("empty: the servers the gateway sends"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Split DNS")
                } footer: {
                    Text("While the tunnel is up, the daemon writes /etc/resolver files for these domains and removes them when it goes down. With no domains, the gateway's DNS servers take over all lookups while the tunnel is up.")
                }
                Section {
                    TextField("Service check URL", text: Binding(get: { profile.checkURL?.absoluteString ?? "" }, set: { profile.checkURL = URL(string: $0) }), prompt: Text("https://service.behind.the.tunnel/"))
                    Toggle("Don't verify the certificate", isOn: $profile.insecureTLS)
                    Toggle("Connect when VPN Widget starts", isOn: $profile.autoConnect)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Install…" : "Apply…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || saving)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func normalizeGateway() {
        if let t = profile.tunnel { profile.tunnel = t.normalized }
    }

    private func save() {
        normalizeGateway()
        var p = profile
        p.dnsDomains = domainsText.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { ResolverFiles.normalizeDomain(String($0)) }
        p.dnsServers = serversText.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter(ResolverFiles.isServer)
        if let t = p.tunnel { p.id = TunnelConfig.profileID(name: t.name) }
        if p.providerKind != kind.providerKind { p.providerKind = kind.providerKind }
        saving = true
        errorText = nil
        let ok = model.saveTunnel(p, password: password.isEmpty ? nil : password)
        saving = false
        if ok {
            dismiss()
        } else {
            errorText = model.settingsError
            model.settingsError = nil
        }
    }
}
