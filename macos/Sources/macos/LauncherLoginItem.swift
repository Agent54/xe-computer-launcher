import ServiceManagement

/// Keep the saved preference and the system registration separate: macOS may
/// require approval even after registration succeeds.
struct LauncherLoginItem {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void

    static var main: Self {
        Self(
            status: { SMAppService.mainApp.status },
            register: { try SMAppService.mainApp.register() },
            unregister: { try SMAppService.mainApp.unregister() }
        )
    }

    func apply(enabled: Bool) throws {
        switch status() {
        case .enabled, .requiresApproval:
            if !enabled { try unregister() }
        case .notRegistered, .notFound:
            if enabled { try register() }
        @unknown default:
            if enabled { try register() }
            else { try unregister() }
        }
    }
}
