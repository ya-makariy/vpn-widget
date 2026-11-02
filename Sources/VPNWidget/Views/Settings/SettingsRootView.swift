import SwiftUI

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model
    /// `VPNWIDGET_PREVIEW=settings:<tab>` opens that tab, for screenshots.
    @State private var tab: String = ProcessInfo.processInfo.environment["VPNWIDGET_PREVIEW"].flatMap { $0.split(separator: ":").dropFirst().first.map(String.init) } ?? "vpns"

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("VPNs", systemImage: "lock.shield", value: "vpns") {
                ProfilesSettingsView()
            }
            Tab("Tunnels", systemImage: "terminal", value: "tunnels") {
                TunnelsSettingsView()
            }
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettingsView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .alert("Settings", isPresented: Binding(get: { model.settingsError != nil }, set: { if !$0 { model.settingsError = nil } })) {
            Button("OK") { model.settingsError = nil }
        } message: {
            Text(model.settingsError ?? "")
        }
    }
}
