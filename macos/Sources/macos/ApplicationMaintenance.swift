import AppKit
import Darwin

enum ApplicationMaintenance {
    enum Action: String {
        case restart = "--xe-restart-after-exit"
        case uninstall = "--xe-uninstall-after-exit"
    }

    /// Start only after normal component shutdown. The helper waits for this
    /// process to exit, so relaunch and archival cannot race its remaining I/O.
    static func schedule(_ action: Action) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw MaintenanceError("The launcher executable could not be located.")
        }
        let helper = Process()
        helper.executableURL = executableURL
        helper.arguments = [action.rawValue, String(ProcessInfo.processInfo.processIdentifier)]
        helper.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    /// This mode deliberately runs before launcher state or services initialize.
    @MainActor
    static func runHelperIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, let action = Action(rawValue: arguments[1]),
              let parentPID = pid_t(arguments[2]), parentPID > 1 else { return false }
        do {
            // If the parent exited before the helper started, launchd has
            // already adopted us. Do not wait on a potentially reused PID.
            if getppid() == parentPID { try waitForExit(of: parentPID) }
            switch action {
            case .restart:
                try relaunch()
            case .uninstall:
                try validateAppBundle(Bundle.main.bundleURL)
                if let warning = PrivilegedPortService.unregisterIfRegistered() {
                    throw MaintenanceError(warning)
                }
                let archiveURL = try archiveData(at: ExternalState.appDataURL)
                do {
                    try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
                } catch {
                    throw MaintenanceError("App data was archived at \(archiveURL.path), but the launcher app could not be moved to Trash: \(error.localizedDescription)")
                }
            }
        } catch {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = action == .restart ? "Couldn’t Restart Xe" : "Uninstall Could Not Finish"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        return true
    }

    static func waitForExit(of pid: pid_t, timeout: TimeInterval = 30) throws {
        let queue = kqueue()
        guard queue >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(queue) }
        var event = kevent(
            ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil
        )
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            if errno == ESRCH { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            var duration = timespec(tv_sec: Int(remaining), tv_nsec: Int(remaining.truncatingRemainder(dividingBy: 1) * 1e9))
            let count = kevent(queue, nil, 0, &event, 1, &duration)
            if count > 0 { return }
            if count < 0 && errno == EINTR { continue }
            if count < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw MaintenanceError("Xe Launcher did not exit. No restart or app data changes were made.")
        }
    }

    private static func relaunch() throws {
        let process = Process()
        if Bundle.main.bundleURL.pathExtension == "app" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundleURL.path]
        } else {
            // Also support running an unbundled development executable.
            process.executableURL = Bundle.main.executableURL
        }
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        try process.run()
        if Bundle.main.bundleURL.pathExtension == "app" {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MaintenanceError("macOS could not reopen Xe Launcher. Open it from \(Bundle.main.bundleURL.path).")
            }
        }
    }

    @MainActor
    static func validateAppBundle(_ bundleURL: URL) throws {
        guard bundleURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw MaintenanceError("Uninstall requires a launcher .app bundle. This development executable will not be removed.")
        }
        guard !ApplicationInstaller.isRunningFromDiskImage(bundleURL: bundleURL) else {
            throw MaintenanceError("This launcher is on a read-only disk image. Eject the disk image to remove it.")
        }
    }

    /// Move entries, including links and settings files, without following
    /// external storage links. Existing archives stay in place.
    static func archiveData(
        at dataURL: URL,
        now: Date = Date(),
        moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> URL {
        let fm = FileManager.default
        let archiveRoot = dataURL.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: archiveRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try fm.attributesOfItem(atPath: archiveRoot.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw MaintenanceError("The app data archive location must be a directory, not a symbolic link: \(archiveRoot.path)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss.SSS"
        let timestamp = formatter.string(from: now)
        var archiveURL = archiveRoot.appendingPathComponent(timestamp, isDirectory: true)
        var suffix = 1
        while mkdir(archiveURL.path, 0o700) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            suffix += 1
            archiveURL = archiveRoot.appendingPathComponent("\(timestamp)-\(suffix)", isDirectory: true)
        }
        var moved: [URL] = []
        do {
            let entries = try fm.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != "archive" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for source in entries {
                try moveItem(source, archiveURL.appendingPathComponent(source.lastPathComponent))
                moved.append(source)
            }
        } catch {
            var rollbackFailures: [String] = []
            for source in moved.reversed() {
                do { try fm.moveItem(at: archiveURL.appendingPathComponent(source.lastPathComponent), to: source) }
                catch { rollbackFailures.append(source.lastPathComponent) }
            }
            if rollbackFailures.isEmpty { try? fm.removeItem(at: archiveURL) }
            let detail = rollbackFailures.isEmpty ? "Moved entries were restored." :
                "Some entries remain in \(archiveURL.path): \(rollbackFailures.joined(separator: ", "))."
            throw MaintenanceError("App data could not be archived: \(error.localizedDescription)\n\n\(detail) The launcher app was kept.")
        }
        return archiveURL
    }

    private struct MaintenanceError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
