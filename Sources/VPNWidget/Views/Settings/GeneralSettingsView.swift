import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .disabled(!model.launchAtLoginAvailable)
                Toggle("Notify when a VPN or its service changes state", isOn: $model.notificationsEnabled)
            } footer: {
                if !model.launchAtLoginAvailable {
                    Text("Launch at login needs the app to run from its bundle.")
                }
            }
            Section("Checks") {
                Picker("Check every", selection: $model.pollIntervalSeconds) {
                    ForEach(SettingsStore.pollIntervals, id: \.self) { s in
                        Text("\(s) seconds").tag(s)
                    }
                }
                Text("While a service has just stopped answering, checks run every second until it is clear whether the failure lasts. A new tunnel has 30 seconds to settle before a failed check counts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")
                LabeledContent("Profiles", value: "\(model.config.profiles.count) shown of \(model.discovered.count) in the system")
                Link("github.com/ya-makariy/vpn-widget", destination: URL(string: "https://github.com/ya-makariy/vpn-widget")!)
            }
        }
        .formStyle(.grouped)
    }
}
