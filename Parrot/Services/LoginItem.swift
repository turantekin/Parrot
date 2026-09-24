import Foundation
import ServiceManagement

/// "Open Parrot at login", through `SMAppService.mainApp` (macOS 13+): the
/// system's own login-items list, shown in System Settings → General →
/// Login Items, where the user can always switch it off. No helper app, no
/// launch agent file of ours.
///
/// Call detection only works while Parrot runs, which is why this sits next
/// to it in Settings and onboarding.
enum LoginItem {

    enum State: Equatable {
        case on
        case off
        /// Registered, but macOS wants the user to allow it in Login Items.
        case needsApproval
        /// This build can't be a login item (e.g. run from the build folder
        /// rather than an installed .app).
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .off
        }
    }

    /// Turns the login item on or off. Returns the state afterwards and an
    /// error message worth showing, if any.
    @discardableResult
    static func set(_ enabled: Bool) -> (state: State, error: String?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return (state, nil)
        } catch {
            NSLog("Parrot: login item \(enabled ? "register" : "unregister") failed, \(error.localizedDescription)")
            return (state, error.localizedDescription)
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
