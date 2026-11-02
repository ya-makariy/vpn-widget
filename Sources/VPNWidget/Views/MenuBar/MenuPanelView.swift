import SwiftUI
import VPNWidgetCore

/// What drops down from the status item.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Namespace private var glass
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                emptyState
            } else {
                // The list takes the height of its rows, up to a limit, and
                // scrolls past it.
                ScrollView {
                    GlassEffectContainer(spacing: Metrics.panelPadding) {
                        VStack(spacing: 6) {
                            ForEach(model.rows) { row in
                                ProfileRowView(row: row, namespace: glass)
                            }
                        }
                    }
                    .padding(Metrics.panelPadding)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, Metrics.rowMinHeight), Metrics.panelMaxHeight))
                .scrollBounceBehavior(.basedOnSize)
            }
            PanelFooterView(openSettings: openSettings)
        }
        .frame(width: Metrics.panelWidth)
        .background { PanelKeyHandler() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No VPNs shown", systemImage: "lock.shield")
        } description: {
            Text("Choose which VPN profiles to show in Settings.")
        } actions: {
            Button("Open Settings…") { SettingsOpener.open(with: openSettings) }
                .buttonStyle(.glassProminent)
        }
        .frame(minHeight: 200)
        .padding(.horizontal, Metrics.panelPadding)
    }
}

/// Keyboard shortcuts for the panel: Escape closes it.
private struct PanelKeyHandler: View {
    var body: some View {
        Color.clear
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.escape) {
                NSApp.keyWindow?.close()
                return .handled
            }
    }
}
