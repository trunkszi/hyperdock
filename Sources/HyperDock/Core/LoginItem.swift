import Foundation
import ServiceManagement

/// Registers HyperDock to start at login.
///
/// `SMAppService.mainApp` works for an ad-hoc signed build — verified moving through
/// `notFound → enabled → notRegistered` with no prompt and no Developer ID.
enum LoginItem {
    /// Whether HyperDock is registered, including a registration still waiting for the
    /// user's approval.
    ///
    /// `.requiresApproval` counts as on. `register()` succeeds into that state when the
    /// user has switched HyperDock off under Login Items, or the system wants a first
    /// approval; reading only `.enabled` showed the switch snapping back off the moment it
    /// was turned on, with nothing to say why or what to do. The registration is real and
    /// takes effect once approved, which `needsApproval` lets the settings say.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    /// Registered, but macOS will not run it at login until the user approves it in
    /// System Settings ▸ General ▸ Login Items.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("HyperDock: could not \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }
}
