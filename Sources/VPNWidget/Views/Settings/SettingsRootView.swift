import SwiftUI

struct SettingsRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Tab("VPNs", systemImage: "lock.shield") {
                ProfilesSettingsView()
            }
            Tab("General", systemImage: "gearshape") {
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
