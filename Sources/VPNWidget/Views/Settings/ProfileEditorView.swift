import SwiftUI
import VPNWidgetCore

/// One profile's settings. Edits save as they are made.
struct ProfileEditorView: View {
    @Environment(AppModel.self) private var model
    @State var profile: VPNProfile
    @State private var urlText: String

    init(profile: VPNProfile) {
        _profile = State(initialValue: profile)
        _urlText = State(initialValue: profile.checkURL?.absoluteString ?? "")
    }

    private var row: ProfileRowState? { model.rows.first { $0.id == profile.id } }
    private var systemName: String? { model.discovered.first { $0.id == profile.id }?.name }

    var body: some View {
        Form {
            Section {
                TextField("Name in the panel", text: $profile.displayName)
                LabeledContent("Client", value: profile.providerKind.displayName)
                if let systemName, systemName != profile.displayName {
                    LabeledContent("Profile in the client", value: systemName)
                }
                Toggle("Connect when VPN Widget starts", isOn: $profile.autoConnect)
            } header: {
                Text("Profile")
            } footer: {
                if profile.providerKind.signsInInteractively {
                    Text("\(profile.providerKind.displayName) asks for a sign-in in its own window when connecting.")
                }
            }

            Section {
                TextField("Check URL", text: $urlText, prompt: Text("https://service.behind.the.tunnel/"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit(commitURL)
                    .onChange(of: urlText) { _, _ in commitURL() }
                Toggle("Don't verify the certificate", isOn: $profile.insecureTLS)
                if let row, row.hasCheck, !row.checkDescription.isEmpty {
                    LabeledContent("Last check", value: row.checkDescription)
                }
            } header: {
                Text("Service check")
            } footer: {
                Text("One GET every check interval, without redirects or proxy. Any answer below HTTP 500 counts as reachable. Turn off certificate verification for services behind a private CA; the check is about reach, not trust. Leave the URL empty to skip the check.")
            }

            SplitDNSSectionView(profile: $profile)

            if let row, row.takesOverDNS || row.isPrimaryInterface {
                Section("Warnings") {
                    if row.takesOverDNS {
                        Label("This tunnel's DNS servers answer every query while it is up. Names of other tunnels may fail to resolve. Resolver files for their domains fix that.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if row.isPrimaryInterface {
                        Label("This tunnel carries the default route: all traffic, including other tunnels' handshakes, goes through it.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: profile) { _, new in model.update(new) }
        .onChange(of: model.config) { _, config in
            // Keep edits made elsewhere, such as Fill from Current Connection.
            if let fresh = config.profiles.first(where: { $0.id == profile.id }), fresh != profile {
                profile = fresh
                urlText = fresh.checkURL?.absoluteString ?? ""
            }
        }
    }

    private func commitURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if profile.checkURL != nil { profile.checkURL = nil }
            return
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            if profile.checkURL != url { profile.checkURL = url }
        }
    }
}
