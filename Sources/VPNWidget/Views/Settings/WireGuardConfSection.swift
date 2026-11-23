import AppKit
import SwiftUI
import VPNWidgetCore

/// The part of the tunnel form that takes an AmneziaWG or WireGuard `.conf`:
/// a file picker, and what the file says without its keys. The text itself
/// goes to the root-only store with Install, the way a password does.
struct WireGuardConfSection: View {
    @Environment(AppModel.self) private var model
    var summary: WireGuardSummary?
    /// A config is stored for this tunnel already.
    var stored: Bool
    /// A file was picked in this form and is not installed yet.
    var pending: Bool
    var onImport: (_ text: String, _ conf: WireGuardConf, _ title: String) -> Void
    @State private var errorText: String?

    var body: some View {
        Section {
            HStack {
                if pending {
                    Label("Imported; not installed yet", systemImage: "doc.badge.plus")
                } else if stored {
                    Label("Stored; import again to replace", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Label("No config yet", systemImage: "circle.dashed").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import .conf…") { pick() }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let toolText {
                Label(toolText, systemImage: "terminal")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let summary {
                LabeledContent("Endpoint", value: summary.endpoints.joined(separator: ", "))
                LabeledContent("Addresses", value: summary.addresses.joined(separator: ", "))
                LabeledContent("Allowed IPs", value: summary.allowedIPs.isEmpty ? "none" : summary.allowedIPs.joined(separator: ", "))
                LabeledContent("DNS", value: summary.dnsServers.isEmpty ? "none" : summary.dnsServers.joined(separator: ", "))
                if let mtu = summary.mtu {
                    LabeledContent("MTU", value: String(mtu))
                }
                if summary.defaultRoute {
                    Label("This tunnel carries the default route: all traffic, including other tunnels' handshakes, goes through it.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !summary.ignoredKeys.isEmpty {
                    Label("\(summary.ignoredKeys.joined(separator: ", ")) in the file will not be run or used.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if !summary.keepalive {
                    Label("No PersistentKeepalive: the tunnel shows as connected only while traffic keeps its handshake fresh. Add PersistentKeepalive = 25 to the peer to hold it.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Config")
        } footer: {
            Text("A wg-quick style file from an AmneziaWG or WireGuard server. It is stored with its keys in a root-only file; the widget keeps only what is shown here. PreUp, PostUp, PreDown and PostDown are never run: the daemon is root, and the file is an imported one.")
        }
    }

    /// What is missing of amneziawg-go and awg, if anything.
    private var toolText: String? {
        guard !model.isFake else { return nil }
        switch TunnelInstaller.wireGuardToolStatus() {
        case .ready:
            return nil
        case .needsSetup(let tools):
            return "\(tools.joined(separator: " and ")) not copied yet: click Set Up Again in the Tunnels tab."
        case .missing(let tools):
            let places = TunnelFiles.wireGuardToolSources("", homebrewPrefix: TunnelInstaller.homebrewPrefix).joined(separator: " or ")
            return "Tool not found: \(tools.joined(separator: " and ")). Build and install to \(places) (see the README), then click Set Up Again in the Tunnels tab."
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an AmneziaWG or WireGuard .conf file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= WireGuardConf.maximumSize else { throw WireGuardConfError("the file is too large for a tunnel config") }
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let conf = try WireGuardConf.parse(text)
            errorText = nil
            onImport(text, conf, url.deletingPathExtension().lastPathComponent)
        } catch let error as WireGuardConfError {
            errorText = "\(url.lastPathComponent): \(error)"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
