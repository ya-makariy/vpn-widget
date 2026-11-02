import AppKit
import SwiftUI

/// Brings the settings window to the front. An accessory app is not active
/// when its panel is used, so opening the window alone would leave it behind.
@MainActor
enum SettingsOpener {
    static func open() {
        NSApp.activate()
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
