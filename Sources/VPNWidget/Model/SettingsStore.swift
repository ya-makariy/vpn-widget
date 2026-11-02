import Foundation
import Observation
import VPNWidgetCore

/// General settings, in UserDefaults.
@Observable
@MainActor
final class SettingsStore {
    static let pollIntervals: [Int] = [10, 15, 30, 60]

    var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: Keys.pollInterval) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let pollInterval = "pollIntervalSeconds"
        static let notifications = "notificationsEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.integer(forKey: Keys.pollInterval)
        pollIntervalSeconds = Self.pollIntervals.contains(interval) ? interval : 30
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
    }
}

/// A notifier that can be switched off from the settings.
final class GatedNotifier: Notifier, @unchecked Sendable {
    private let inner: any Notifier
    private let lock = NSLock()
    private var enabled = true

    init(_ inner: any Notifier) {
        self.inner = inner
    }

    func setEnabled(_ on: Bool) {
        lock.withLock { enabled = on }
    }

    func send(_ notice: Notice) async {
        guard lock.withLock({ enabled }) else { return }
        await inner.send(notice)
    }
}
