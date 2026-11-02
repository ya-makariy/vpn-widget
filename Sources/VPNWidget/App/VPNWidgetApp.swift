import SwiftUI
import VPNWidgetCore

@main
struct VPNWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environment(model)
        } label: {
            StatusIconLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environment(model)
        }

        // `VPNWIDGET_PREVIEW=1` opens the panel in an ordinary window, for
        // screenshots and layout work.
        Window("Panel Preview", id: "panel-preview") {
            MenuPanelView()
                .environment(model)
                .padding(4)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// The status item image, redrawn whenever the model's summary changes.
struct StatusIconLabel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: StatusIconRenderer.shared.image(for: model.aggregate, segments: model.segments, blinkOn: model.blinkOn))
            .accessibilityLabel(StatusIconRenderer.accessibilityLabel(model.aggregate, connected: model.connectedCount, total: model.rows.count))
            .onAppear {
                // VPNWIDGET_PREVIEW=1 opens the panel in a window; "settings" also opens Settings.
                guard let preview = ProcessInfo.processInfo.environment["VPNWIDGET_PREVIEW"] else { return }
                openWindow(id: "panel-preview")
                if preview.hasPrefix("settings") { SettingsOpener.open(with: openSettings) }
                NSApp.activate()
            }
    }
}
