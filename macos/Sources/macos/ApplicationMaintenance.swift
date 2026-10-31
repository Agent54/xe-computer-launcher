import AppKit
import Darwin
import LauncherMaintenance

extension ApplicationMaintenance {
    /// Startup state is established atomically and retained until process exit.
    struct Context {
        let lifecycle: LauncherLifecycle
        let data: AnchoredDirectory
        let bundle: BundleIdentity

        init() throws {
            lifecycle = try LauncherLifecycle()
            data = try AnchoredDirectory(ExternalState.appDataURL, create: true)
            try data.requirePrivateOwner()
            bundle = try BundleIdentity.capture()
        }
    }

    @MainActor static var context: Context?

    @MainActor static func prepare(_ action: Action) throws -> Request {
        guard let context else { throw MaintenanceFailure("The launcher has no validated startup state.") }
        if action == .uninstall { try validateAppBundle(Bundle.main.bundleURL) }
        try context.lifecycle.validate()
        try context.data.validate()
        try context.bundle.validate()
        return Request(action: action, nonce: UUID().uuidString, data: context.data.identity,
                       lifecycle: context.lifecycle.directory.identity, bundle: context.bundle)
    }

    @MainActor static func schedule(_ request: Request) async throws -> Handoff {
        guard let context, let executable = Bundle.main.executableURL else {
            throw MaintenanceFailure("The launcher executable or lifecycle lock is unavailable.")
        }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [request.action.rawValue, String(getpid()), request.nonce]
        return try await startHelper(helper, request: request, lifecycle: context.lifecycle)
    }

    @MainActor static func runHelperIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--xe-maintenance-error" {
            showError(arguments[2]); return true
        }
        guard arguments.count > 1, let action = Action(rawValue: arguments[1]) else { return false }
        guard arguments.count == 4, let parentPID = pid_t(arguments[2]), parentPID > 1,
              getppid() == parentPID else { exit(1) }
        var authorized = false
        do {
            if action == .uninstall { try validateAppBundle(Bundle.main.bundleURL) }
            try serve(action: action, nonce: arguments[3], dataURL: ExternalState.appDataURL,
                      lifecycleURL: LauncherLifecycle.directoryURL, bundle: BundleIdentity.capture(),
                      onAuthorization: { authorized = true }, perform: perform)
        } catch {
            // serve releases its lock before error presentation. Invalid
            // invocations exit directly without opening an interactive app.
            if authorized { showError(error.localizedDescription) }
            else { fputs("Maintenance helper rejected: \(error.localizedDescription)\n", stderr) }
            exit(1)
        }
        return true
    }

    @MainActor private static func perform(_ request: Request, data: AnchoredDirectory) throws {
        switch request.action {
        case .restart:
            let process = Process()
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            process.executableURL = bundled ? URL(fileURLWithPath: "/usr/bin/open") : Bundle.main.executableURL
            process.arguments = bundled ? ["-n", Bundle.main.bundleURL.path] : []
            try runBounded(process, timeout: 15, waitForExit: bundled)
        case .uninstall:
            if let warning = PrivilegedPortService.unregisterIfRegistered() { throw MaintenanceFailure(warning) }
            let archive = try archiveData(in: data)
            do { try trashApprovedBundle(request.bundle) }
            catch { throw MaintenanceFailure("App data was archived at \(archive.path), but the launcher app was kept: \(error.localizedDescription)") }
        }
    }

    @MainActor static func reportFailure(_ message: String) {
        // A separate reporter cannot block termination or retain the lock while
        // waiting for someone to dismiss the dialog.
        let reporter = Process()
        reporter.executableURL = Bundle.main.executableURL
        reporter.arguments = ["--xe-maintenance-error", message]
        reporter.currentDirectoryURL = URL(fileURLWithPath: "/")
        reporter.standardInput = FileHandle.nullDevice
        reporter.standardOutput = FileHandle.nullDevice
        reporter.standardError = FileHandle.nullDevice
        try? reporter.run()
    }

    @MainActor private static func showError(_ message: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Xe Maintenance Could Not Finish"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor static func validateAppBundle(_ bundleURL: URL) throws {
        guard bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil,
              Bundle(url: bundleURL)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw MaintenanceFailure("Uninstall requires this launcher's installed .app bundle.")
        }
        guard !ApplicationInstaller.isRunningFromDiskImage(bundleURL: bundleURL) else {
            throw MaintenanceFailure("This launcher is on a read-only disk image. Eject the disk image to remove it.")
        }
    }
}
