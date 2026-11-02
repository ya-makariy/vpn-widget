import SwiftUI

struct PanelFooterView: View {
    @Environment(AppModel.self) private var model
    var openSettings: OpenSettingsAction

    var body: some View {
        HStack(spacing: 8) {
            Button("Connect All") { model.connectAll() }
                .buttonStyle(.glassProminent)
                .disabled(!model.canConnectAll)
                .keyboardShortcut("a", modifiers: [.command])
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("Refresh")
            Spacer()
            Button { SettingsOpener.open(with: openSettings) } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .keyboardShortcut(",", modifiers: [.command])
            .accessibilityLabel("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("q", modifiers: [.command])
            .accessibilityLabel("Quit VPN Widget")
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.panelPadding + 2)
        .padding(.vertical, Metrics.panelPadding)
    }
}
