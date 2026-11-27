import SwiftUI
import VPNWidgetCore

/// Tunnels the widget runs itself: setting up once, then adding, changing and
/// removing them. Each change goes through the administrator prompt.
struct TunnelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
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
                        } else if let name = profile.tunnel?.name, model.tunnelsOnOlderHelper.contains(name) {
                            Label("Reconnect to update", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("The tunnel runs the helper from before the last update; it takes the new one when it reconnects.")
                        }
                        Button("Log") { TunnelLogOpener.open(profile.id, with: openWindow) }
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
                Text("A tunnel is a launchd job on this Mac that runs openfortivpn, openconnect or amneziawg-go as root. The widget starts and stops it without a password through a sudoers rule limited to these jobs. Connecting needs no other app: a SAML sign-in opens in the browser.")
            }
            if !model.sharedNetworks.isEmpty {
                SharedNetworksSection()
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

/// Networks two or more connected tunnels route: which one has the real
/// addresses, and the stand-in ranges the others reach theirs through.
struct SharedNetworksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.sharedNetworks) { shared in
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: Binding(
                        get: { shared.holder ?? "" },
                        set: { if !$0.isEmpty, $0 != shared.holder { model.chooseHolder($0, of: shared.network, members: shared.members.map(\.tunnel)) } }
                    )) {
                        if shared.holder == nil {
                            Text("Another VPN").tag("")
                        }
                        ForEach(shared.members, id: \.tunnel) { member in
                            Text(model.tunnelDisplayName(member.tunnel)).tag(member.tunnel)
                        }
                    } label: {
                        Text(verbatim: shared.network).font(.body.monospaced())
                    }
                    .disabled(shared.holder == nil)
                    ForEach(shared.members.filter { $0.tunnel != shared.holder && $0.fake != nil }, id: \.tunnel) { member in
                        Text(verbatim: "\(model.tunnelDisplayName(member.tunnel)): through \(member.fake ?? "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if shared.holder == nil {
                        Text("A VPN app outside the widget has this network; it is not ours to move.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Shared networks")
        } footer: {
            Text("These networks are routed by more than one tunnel. The tunnel chosen here gets the real addresses; each of the others reaches its own hosts through a stand-in range from the documentation networks (TCP only), and names in its split-DNS domains resolve to their stand-ins. Choosing reconnects the tunnels that share the network.")
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
    @State private var checkURLText: String
    /// amneziawg: the `.conf` picked in this form. It has the keys in it, and
    /// goes where the password goes.
    @State private var confText: String?

    init(profile: VPNProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        self.isNew = isNew
        _domainsText = State(initialValue: profile.dnsDomains.joined(separator: " "))
        // A new AmneziaWG tunnel starts with a public resolver for its domains,
        // unless its .conf brings DNS servers (see `imported`).
        let newWireGuard = isNew && profile.tunnel?.kind == .amneziawg && profile.dnsServers.isEmpty
        _serversText = State(initialValue: newWireGuard ? Self.defaultWireGuardDNS : profile.dnsServers.joined(separator: " "))
        _checkURLText = State(initialValue: profile.checkURL?.absoluteString ?? "")
    }

    private var tunnel: Binding<TunnelConfig> {
        Binding(get: { profile.tunnel ?? TunnelConfig(name: "", kind: .openfortivpn, host: "", port: 8443) }, set: { profile.tunnel = $0 })
    }

    private var kind: TunnelConfig.Kind { profile.tunnel?.kind ?? .openfortivpn }

    private var canSave: Bool {
        guard let t = profile.tunnel else { return false }
        let nameOK = isNew ? TunnelConfig.isValidName(t.name) : TunnelConfig.isInstalledName(t.name)
        if kind == .amneziawg {
            return nameOK && !profile.displayName.isEmpty && (confText != nil || t.hasSecret) && checkURL.isValid
        }
        return nameOK && TunnelConfig.parseGateway(t.host) != nil && (1...65535).contains(t.port) && !profile.displayName.isEmpty
            && (kind != .openconnect || !(t.username ?? "").isEmpty)
            && checkURL.isValid
    }

    /// Why the tunnel name is refused, or, for an installed tunnel, why it
    /// should be replaced.
    private var nameHint: String? {
        let name = profile.tunnel?.name ?? ""
        guard !name.isEmpty, !TunnelConfig.isValidName(name) else { return nil }
        if !isNew {
            return "This name has non-ASCII letters, so it cannot be typed in a terminal. The tunnel keeps working; to fix the name, remove the tunnel and add it again."
        }
        if !name.unicodeScalars.allSatisfy(\.isASCII) {
            return "The name has non-ASCII characters, such as a Cyrillic letter that looks like a Latin one. Use only a-z, 0-9 and dashes."
        }
        return "Use only lowercase a-z, 0-9 and dashes, at most 40 characters, with no dash at either end."
    }

    private var checkURL: CheckURL.Parsed { CheckURL.parse(checkURLText) }

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
                    if let nameHint {
                        Text(nameHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if kind != .amneziawg {
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
                }
                if kind == .amneziawg {
                    WireGuardConfSection(summary: tunnel.wrappedValue.wireGuard, stored: tunnel.wrappedValue.hasSecret, pending: confText != nil, onImport: imported)
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
                } else if kind == .openconnect {
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
                    TextField("DNS servers", text: $serversText, prompt: Text(kind == .amneziawg ? "empty: the DNS line of the config" : "empty: the servers the gateway sends"))
                        .autocorrectionDisabled()
                } header: {
                    Text("Split DNS")
                } footer: {
                    Text(kind == .amneziawg
                        ? "While the tunnel is up, the daemon writes /etc/resolver files for these domains and removes them when it goes down. The config's DNS servers are used for these domains only, never as the system's resolver: with no domains, the tunnel changes no DNS."
                        : "While the tunnel is up, the daemon writes /etc/resolver files for these domains and removes them when it goes down. With no domains, the gateway's DNS servers take over all lookups while the tunnel is up.")
                }
                Section {
                    Picker("Level", selection: tunnel.logLevel) {
                        ForEach(TunnelConfig.LogLevel.allCases, id: \.self) { level in
                            Text(verbatim: level.displayName).tag(level)
                        }
                    }
                    Stepper(value: tunnel.logRetentionDays, in: TunnelConfig.logRetentionRange) {
                        Text("Keep archives for \(tunnel.wrappedValue.logRetentionDays) days")
                    }
                } header: {
                    Text("Log")
                } footer: {
                    Text("The log is rotated every day at midnight: the day's file is compressed and kept for this many days. ERROR keeps failures only; DEBUG adds the tool's own debug output, TRACE its packet traces. Changes apply the next time the tunnel starts.")
                }
                Section {
                    TextField("Service check URL", text: $checkURLText, prompt: Text("https://service.behind.the.tunnel/"))
                        .autocorrectionDisabled()
                        .onSubmit(normalizeCheckURL)
                    if !checkURL.isValid {
                        Text("Not an http or https URL with a host.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let url = checkURL.url, url.absoluteString != checkURLText {
                        Text("Will check \(url.absoluteString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .frame(width: 560, height: 680)
    }

    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    /// Takes a picked `.conf`: its summary into the profile, its DNS as the
    /// split-DNS servers when none are typed, its file name as the title.
    /// Quad9: it answers names that point at private addresses, which home
    /// routers' resolvers often drop (DNS rebinding protection), and it is
    /// reachable over UDP where some networks hold back 1.1.1.1 and 8.8.8.8.
    /// The field stays editable.
    static let defaultWireGuardDNS = "9.9.9.9"

    private func imported(_ text: String, _ conf: WireGuardConf, _ title: String) {
        confText = text
        tunnel.wrappedValue.apply(conf)
        // The .conf's own DNS wins over the default; anything typed stays.
        let typed = serversText.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty || (typed == Self.defaultWireGuardDNS && !conf.dnsServers.isEmpty) {
            serversText = conf.dnsServers.isEmpty ? Self.defaultWireGuardDNS : conf.dnsServers.joined(separator: " ")
        }
        if domainsText.trimmingCharacters(in: .whitespaces).isEmpty { domainsText = conf.dnsSearchDomains.joined(separator: " ") }
        if isNew, profile.displayName.isEmpty { profile.displayName = title }
    }

    private func normalizeGateway() {
        if let t = profile.tunnel { profile.tunnel = t.normalized }
    }

    private func normalizeCheckURL() {
        if let url = checkURL.url { checkURLText = url.absoluteString }
    }

    private func save() {
        normalizeGateway()
        guard checkURL.isValid else { return }
        normalizeCheckURL()
        var p = profile
        p.checkURL = checkURL.url
        p.dnsDomains = domainsText.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { ResolverFiles.normalizeDomain(String($0)) }
        p.dnsServers = serversText.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init).filter(ResolverFiles.isServer)
        if let t = p.tunnel { p.id = TunnelConfig.profileID(name: t.name) }
        if p.providerKind != kind.providerKind { p.providerKind = kind.providerKind }
        saving = true
        errorText = nil
        let ok = model.saveTunnel(p, password: kind == .amneziawg ? confText : password.isEmpty ? nil : password)
        saving = false
        if ok {
            dismiss()
        } else {
            errorText = model.settingsError
            model.settingsError = nil
        }
    }
}
