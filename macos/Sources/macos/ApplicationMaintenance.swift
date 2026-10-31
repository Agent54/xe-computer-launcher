import AppKit
import Darwin

struct ShutdownResult: Codable, Sendable {
    enum Component: String, Codable, CaseIterable { case containerVM, browserStack, hostServices }
    let stopped: Set<Component>
    let failures: [String]
    var succeeded: Bool { stopped == Set(Component.allCases) && failures.isEmpty }
}

enum ApplicationMaintenance {
    enum Action: String, Codable, Sendable {
        case restart = "--xe-restart-after-exit"
        case uninstall = "--xe-uninstall-after-exit"
    }

    struct BundleIdentity: Codable, Equatable, Sendable {
        let directory: AnchoredDirectory.Identity
        let executableDirectory: AnchoredDirectory.Identity
        let executableName: String
        let executable: FileIdentity
        let contents: AnchoredDirectory.Identity?
        let info: FileIdentity?

        static func capture(bundleURL: URL = Bundle.main.bundleURL, executableURL: URL? = Bundle.main.executableURL) throws -> Self {
            guard let executableURL else { throw MaintenanceFailure("The launcher executable is missing.") }
            let directory = try AnchoredDirectory(bundleURL)
            let executables = try AnchoredDirectory(executableURL.deletingLastPathComponent())
            let contents = bundleURL.pathExtension == "app"
                ? try AnchoredDirectory(bundleURL.appendingPathComponent("Contents")) : nil
            return Self(directory: directory.identity, executableDirectory: executables.identity,
                        executableName: executableURL.lastPathComponent,
                        executable: try executables.entryIdentity(executableURL.lastPathComponent),
                        contents: contents?.identity, info: try contents?.entryIdentity("Info.plist"))
        }

        func validate() throws {
            _ = try AnchoredDirectory(URL(fileURLWithPath: directory.path), expected: directory)
            let executables = try AnchoredDirectory(URL(fileURLWithPath: executableDirectory.path), expected: executableDirectory)
            guard try executables.entryIdentity(executableName) == executable else {
                throw MaintenanceFailure("The approved launcher executable was replaced.")
            }
            if let contents {
                let contents = try AnchoredDirectory(URL(fileURLWithPath: contents.path), expected: contents)
                guard try contents.entryIdentity("Info.plist") == info else {
                    throw MaintenanceFailure("The approved launcher bundle was replaced.")
                }
            }
        }
    }

    struct Request: Codable, Sendable {
        let action: Action
        let nonce: String
        let data: AnchoredDirectory.Identity
        let lifecycle: AnchoredDirectory.Identity
        let bundle: BundleIdentity
    }

    struct Message: Codable {
        let kind: String
        var request: Request? = nil
        var shutdown: ShutdownResult? = nil
        var detail: String? = nil
    }

    /// stdin is the inherited lifecycle lock; stdout is a private duplex
    /// socket. Neither a CLI flag nor a PID alone authorizes maintenance.
    final class Channel: @unchecked Sendable {
        let handle: FileHandle
        private var buffered = Data()

        init(_ handle: FileHandle) throws {
            self.handle = handle
            var value: Int32 = 1
            guard setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0,
                  fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw posixFailure() }
        }

        func send(_ message: Message) throws {
            var data = try JSONEncoder().encode(message)
            data.append(10)
            guard data.count <= 65_536 else { throw MaintenanceFailure("Maintenance message is too large.") }
            let deadline = Date().addingTimeInterval(5)
            var offset = 0
            while offset < data.count {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MaintenanceFailure("Maintenance send timed out.") }
                var event = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let result = poll(&event, 1, Int32(remaining * 1000 + 1))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw MaintenanceFailure("Maintenance send failed.") }
                let count = data.withUnsafeBytes { bytes in
                    Darwin.send(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }

        func receive(timeout: TimeInterval) throws -> Message? {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let end = buffered.firstIndex(of: 10) {
                    let message = try JSONDecoder().decode(Message.self, from: buffered[..<end])
                    buffered.removeSubrange(...end)
                    return message
                }
                guard buffered.count < 65_536 else { throw MaintenanceFailure("Maintenance message is too large.") }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MaintenanceFailure("Maintenance handoff timed out.") }
                var event = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let result = poll(&event, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw MaintenanceFailure("Maintenance handoff timed out or failed.") }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(handle.fileDescriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw posixFailure() }
                if count == 0 {
                    guard buffered.isEmpty else { throw MaintenanceFailure("Incomplete maintenance authorization.") }
                    return nil
                }
                buffered.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    final class Handoff {
        let process: Process
        let channel: Channel
        init(process: Process, channel: Channel) { self.process = process; self.channel = channel }

        func authorize(_ shutdown: ShutdownResult) throws {
            guard shutdown.succeeded else { throw MaintenanceFailure("Maintenance cancelled because not every component stopped successfully.") }
            try channel.send(Message(kind: "commit", shutdown: shutdown))
            guard try channel.receive(timeout: 5)?.kind == "committed" else {
                throw MaintenanceFailure("The maintenance helper did not acknowledge authorization.")
            }
            // Keep this channel alive until the launcher exits. The helper
            // requires both explicit commit and EOF before doing any work.
        }

        func cancel() {
            try? channel.handle.close()
            if process.isRunning { process.terminate() }
        }
    }

#if !MAINTENANCE_FIXTURE
    @MainActor static var dataDirectory: AnchoredDirectory?
    @MainActor static var startupBundle: BundleIdentity?

    @MainActor static func prepare(_ action: Action) throws -> Request {
        guard let lifecycle = LauncherLifecycle.current, let dataDirectory, let startupBundle else {
            throw MaintenanceFailure("The launcher has no validated startup state.")
        }
        try lifecycle.validate()
        try dataDirectory.validate()
        try startupBundle.validate()
        return Request(action: action, nonce: UUID().uuidString, data: dataDirectory.identity,
                       lifecycle: lifecycle.directory.identity, bundle: startupBundle)
    }
#endif

    static func schedule(_ request: Request, lifecycle: LauncherLifecycle,
                         executableURL: URL? = Bundle.main.executableURL,
                         arguments: [String]? = nil, environment: [String: String]? = nil) throws -> Handoff {
        try lifecycle.validate()
        guard let executableURL else { throw MaintenanceFailure("The launcher executable could not be located.") }
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw posixFailure() }
        let parent = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        let channel = try Channel(parent)
        _ = fcntl(child.fileDescriptor, F_SETFD, FD_CLOEXEC)
        let helper = Process()
        helper.executableURL = executableURL
        helper.arguments = arguments ?? [request.action.rawValue, String(getpid()), request.nonce]
        helper.environment = environment
        helper.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        helper.standardInput = FileHandle(fileDescriptor: lifecycle.descriptor, closeOnDealloc: false)
        helper.standardOutput = child
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        try child.close()
        let handoff = Handoff(process: helper, channel: channel)
        do {
            try channel.send(Message(kind: "prepare", request: request))
            let response = try channel.receive(timeout: 5)
            guard response?.kind == "ready", response?.detail == request.nonce else {
                throw MaintenanceFailure(response?.detail ?? "The maintenance helper exited before becoming ready.")
            }
            return handoff
        } catch { handoff.cancel(); throw error }
    }

#if !MAINTENANCE_FIXTURE
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
            try serve(action: action, nonce: arguments[3], dataURL: ExternalState.appDataURL,
                      lifecycleURL: LauncherLifecycle.directoryURL, bundle: BundleIdentity.capture(),
                      onAuthorization: { authorized = true }, perform: { request, data in
                switch request.action {
                case .restart: try relaunch()
                case .uninstall:
                    try validateAppBundle(Bundle.main.bundleURL)
                    try request.bundle.validate()
                    try data.validate()
                    if let warning = PrivilegedPortService.unregisterIfRegistered() { throw MaintenanceFailure(warning) }
                    let archive = try archiveData(in: data)
                    do { try trashApprovedBundle(request.bundle) }
                    catch { throw MaintenanceFailure("App data was archived at \(archive.path), but the launcher app was kept: \(error.localizedDescription)") }
                }
            })
        } catch {
            // The inherited lock is released before any error dialog. Invalid
            // invocations exit directly instead of becoming an interactive app.
            if authorized { showError(error.localizedDescription) }
            exit(1)
        }
        return true
    }
#endif

    /// Also exercised by subprocess fixtures. Only a successful commit followed
    /// by EOF authorizes work. The lock spans initialization and all data moves.
    static func serve(action: Action, nonce: String, dataURL: URL, lifecycleURL: URL,
                      bundle: BundleIdentity, onAuthorization: () -> Void = {},
                      perform: (Request, AnchoredDirectory) throws -> Void) throws {
        let channel = try Channel(FileHandle(fileDescriptor: STDOUT_FILENO, closeOnDealloc: true))
        do {
            let lifecycle = try LauncherLifecycle(directoryURL: lifecycleURL, inherited: STDIN_FILENO)
            let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard null >= 0, dup2(null, STDIN_FILENO) >= 0 else { throw posixFailure() }
            if null != STDIN_FILENO { close(null) }
            _ = fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC)
            guard let message = try channel.receive(timeout: 5), message.kind == "prepare", let request = message.request,
                  request.action == action, request.nonce == nonce, request.bundle == bundle,
                  request.data.path == dataURL.path, request.lifecycle == lifecycle.directory.identity else {
                throw MaintenanceFailure("Invalid maintenance preparation.")
            }
            let data = try AnchoredDirectory(dataURL, expected: request.data)
            try data.requirePrivateOwner()
            try request.bundle.validate()
            try channel.send(Message(kind: "ready", detail: nonce))
            guard let commit = try channel.receive(timeout: 90), commit.kind == "commit", commit.shutdown?.succeeded == true else {
                throw MaintenanceFailure("Maintenance was not authorized by a successful component shutdown.")
            }
            try channel.send(Message(kind: "committed"))
            guard try channel.receive(timeout: 30) == nil else {
                throw MaintenanceFailure("Unexpected maintenance message after authorization.")
            }
            onAuthorization()
            try lifecycle.validate()
            try data.validate()
            try request.bundle.validate()
            if action == .restart { lifecycle.release() }
            try withExtendedLifetime(lifecycle) { try perform(request, data) }
        } catch {
            try? channel.send(Message(kind: "error", detail: error.localizedDescription))
            throw error
        }
    }

    private static func relaunch() throws {
        let process = Process()
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
        process.executableURL = bundled ? URL(fileURLWithPath: "/usr/bin/open") : Bundle.main.executableURL
        process.arguments = bundled ? ["-n", Bundle.main.bundleURL.path] : []
        try runBounded(process, timeout: 15, waitForExit: bundled)
    }

    static func runBounded(_ process: Process, timeout: TimeInterval, waitForExit: Bool = true) throws {
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        guard waitForExit else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            throw MaintenanceFailure("macOS did not finish reopening Xe Launcher within \(Int(timeout)) seconds.")
        }
        guard process.terminationStatus == 0 else { throw MaintenanceFailure("macOS could not reopen Xe Launcher.") }
    }

    @MainActor static func reportFailure(_ message: String) {
        // A separate reporter cannot block AppKit's termination reply or retain
        // the lifecycle lock while waiting for someone to dismiss a dialog.
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

#if !MAINTENANCE_FIXTURE
    @MainActor static func validateAppBundle(_ bundleURL: URL) throws {
        guard bundleURL.pathExtension == "app", Bundle(url: bundleURL)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              Bundle.main.bundleIdentifier != nil else {
            throw MaintenanceFailure("Uninstall requires this launcher's installed .app bundle.")
        }
        _ = try BundleIdentity.capture(bundleURL: bundleURL)
        guard !ApplicationInstaller.isRunningFromDiskImage(bundleURL: bundleURL) else {
            throw MaintenanceFailure("This launcher is on a read-only disk image. Eject the disk image to remove it.")
        }
    }
#endif
}
