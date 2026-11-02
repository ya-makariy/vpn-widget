import AppKit
import SwiftUI

/// Brings the settings window to the front. An accessory app is not active
/// when its panel is used, so opening the window alone would leave it behind.
@MainActor
enum SettingsOpener {
    /// Asks whichever view holds the `openSettings` action to open the window.
    static let requested = Notification.Name("com.ya-makariy.vpn-widget.openSettings")

    static func open() {
        NSApp.activate()
        NotificationCenter.default.post(name: requested, object: nil)
    }

    static func open(with action: OpenSettingsAction) {
        NSApp.activate()
        action()
        // The window may open behind the panel; raise it once it exists.
        DispatchQueue.main.async {
            NSApp.activate()
            NSApp.windows.first { $0.title.localizedCaseInsensitiveContains("settings") || $0.identifier?.rawValue.contains("Settings") == true }?.makeKeyAndOrderFront(nil)
        }
    }
}
