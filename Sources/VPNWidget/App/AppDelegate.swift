import AppKit

/// Keeps the app out of the Dock, the menu bar and the app switcher while it
/// is only a status item, and makes it a regular app, with its name in the
/// menu bar and the standard menus, while a window of its own (Settings) is
/// open.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, `open -a`, the Dock icon) shows the settings.
        SettingsOpener.open()
        return false
    }

    /// A window of the app's own, as opposed to the status item's panel.
    private static func isRegular(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.level == .normal && !window.className.contains("StatusBar")
    }

    @objc private func windowChanged(_ note: Notification) {
        updatePolicy(closing: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        let closing = note.object as? NSWindow
        // The window is still listed while it closes; decide after it is gone.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updatePolicy(closing: closing) }
        }
    }

    private func updatePolicy(closing: NSWindow?) {
        let open = NSApp.windows.contains { $0 !== closing && Self.isRegular($0) && $0.isVisible }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if open { NSApp.activate() }
    }
}
