import Foundation
import ServiceManagement

/// Launch-at-login, backed by `SMAppService`.
///
/// Registration is per-app and needs no helper bundle or privileged install;
/// macOS shows the result under Login Items in System Settings, where the user
/// can override it. The app is only ever registered from an explicit toggle.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user has actively disabled the app in System Settings.
    /// Re-registering in that state throws, so the toggle surfaces it instead.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return true }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
