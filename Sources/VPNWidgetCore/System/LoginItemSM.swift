import Foundation
import ServiceManagement

/// Starting the widget at login, through the app's own login item.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
