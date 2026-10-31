import Foundation
import Darwin

package struct ShutdownResult: Codable, Sendable {
    package enum Component: String, Codable, CaseIterable { case containerVM, browserStack, hostServices }
    package let stopped: Set<Component>
    package let failures: [String]
    package var succeeded: Bool { stopped == Set(Component.allCases) && failures.isEmpty }
    package init(stopped: Set<Component>, failures: [String]) { self.stopped = stopped; self.failures = failures }
}

package enum ApplicationMaintenance {
    package enum Action: String, Codable, Sendable {
        case restart = "--xe-restart-after-exit"
        case uninstall = "--xe-uninstall-after-exit"
    }

    package struct BundleIdentity: Codable, Equatable, Sendable {
        package let directory: AnchoredDirectory.Identity
        package let executableDirectory: AnchoredDirectory.Identity
        package let executableName: String
        package let executable: FileIdentity
        package let contents: AnchoredDirectory.Identity?
        package let info: FileIdentity?

        package static func capture(bundleURL: URL = Bundle.main.bundleURL, executableURL: URL? = Bundle.main.executableURL) throws -> Self {
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

        package func validate() throws {
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

    package struct Request: Codable, Sendable {
        package let action: Action
        package let nonce: String
        package let data: AnchoredDirectory.Identity
        package let lifecycle: AnchoredDirectory.Identity
        package let bundle: BundleIdentity
        package init(action: Action, nonce: String, data: AnchoredDirectory.Identity,
                     lifecycle: AnchoredDirectory.Identity, bundle: BundleIdentity) {
            self.action = action; self.nonce = nonce; self.data = data; self.lifecycle = lifecycle; self.bundle = bundle
        }
    }

    package enum Message: Codable, Sendable {
        case prepare(Request)
        case ready(String)
        case commit(ShutdownResult)
        case committed
        case failure(String)
    }

    /// stdin is the inherited lifecycle lock; stdout is a private duplex
    /// socket. Neither a CLI flag nor a PID alone authorizes maintenance.
    private final class Channel {
        let handle: FileHandle
        private var buffered = Data()

        init(_ handle: FileHandle) throws {
            self.handle = handle
            var value: Int32 = 1
            guard setsockopt(handle.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
                throw MaintenanceFailure("Maintenance requires an inherited control socket.")
            }
            guard fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw posixFailure() }
        }

        func send(_ message: Message) throws {
            var data = try JSONEncoder().encode(message)
            data.append(10)
            guard data.count <= 65_536 else { throw MaintenanceFailure("Maintenance message is too large.") }
            let deadline = Date().addingTimeInterval(5)
            var offset = 0
            while offset < data.count {
                try wait(for: Int16(POLLOUT), until: deadline)
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
                try wait(for: Int16(POLLIN), until: deadline)
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

        private func wait(for events: Int16, until deadline: Date) throws {
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw MaintenanceFailure("Maintenance handoff timed out.") }
                var event = pollfd(fd: handle.fileDescriptor, events: events, revents: 0)
                let result = poll(&event, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw MaintenanceFailure("Maintenance handoff timed out or failed.") }
                return
            }
        }
    }

    /// Blocking socket I/O stays on this actor, away from AppKit. Cancellation
    /// shuts down the socket without closing/reusing a descriptor under poll().
    package actor Handoff {
        package nonisolated let process: Process
        private nonisolated let connection: FileHandle
        private let channel: Channel

        fileprivate init(process: Process, connection: FileHandle) throws {
            self.process = process
            self.connection = connection
            channel = try Channel(connection)
        }

        package func exchange(_ message: Message, timeout: TimeInterval = 5) throws -> Message? {
            try channel.send(message)
            return try channel.receive(timeout: timeout)
        }

        fileprivate func prepare(_ request: Request) throws {
            let response = try exchange(.prepare(request))
            if case .failure(let detail)? = response { throw MaintenanceFailure(detail) }
            guard case .ready(let nonce)? = response, nonce == request.nonce else {
                throw MaintenanceFailure("The maintenance helper did not acknowledge readiness.")
            }
        }

        package func authorize(_ shutdown: ShutdownResult) throws {
            guard shutdown.succeeded else {
                throw MaintenanceFailure("Maintenance cancelled because not every component stopped successfully.\n\n" + shutdown.failures.joined(separator: "\n"))
            }
            guard case .committed? = try exchange(.commit(shutdown)) else {
                throw MaintenanceFailure("The maintenance helper did not acknowledge authorization.")
            }
            // Keep this channel alive until the launcher exits. The helper
            // requires both explicit commit and EOF before doing any work.
        }

        package nonisolated func cancel() {
            if process.isRunning { process.terminate() }
            _ = Darwin.shutdown(connection.fileDescriptor, SHUT_RDWR)
        }
    }

    @MainActor package static func startHelper(_ helper: Process, request: Request, lifecycle: LauncherLifecycle) async throws -> Handoff {
        try lifecycle.validate()
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw posixFailure() }
        let parent = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
        // Channel initialization marks the parent's endpoint close-on-exec
        // before spawning; the helper must not inherit its own lifetime writer.
        let handoff = try Handoff(process: helper, connection: parent)
        _ = fcntl(child.fileDescriptor, F_SETFD, FD_CLOEXEC)
        helper.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        helper.standardInput = FileHandle(fileDescriptor: lifecycle.descriptor, closeOnDealloc: false)
        helper.standardOutput = child
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
            try child.close()
            return try await withTaskCancellationHandler {
                try await handoff.prepare(request)
                try Task.checkCancellation()
                return handoff
            } onCancel: {
                handoff.cancel()
            }
        } catch { handoff.cancel(); throw error }
    }

    /// Also exercised by subprocess fixtures. Only a successful commit followed
    /// by EOF authorizes work. The lock spans initialization and all data moves.
    package static func serve(action: Action, nonce: String, dataURL: URL, lifecycleURL: URL,
                      bundle: BundleIdentity, onAuthorization: () -> Void = {},
                      perform: (Request, AnchoredDirectory) throws -> Void) throws {
        let channel = try Channel(FileHandle(fileDescriptor: STDOUT_FILENO, closeOnDealloc: true))
        do {
            let lifecycle = try LauncherLifecycle(directoryURL: lifecycleURL, inherited: STDIN_FILENO)
            let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard null >= 0, dup2(null, STDIN_FILENO) >= 0 else { throw posixFailure() }
            if null != STDIN_FILENO { close(null) }
            _ = fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC)
            guard case .prepare(let request)? = try channel.receive(timeout: 5),
                  request.action == action, request.nonce == nonce, request.bundle == bundle,
                  request.data.path == dataURL.path, request.lifecycle == lifecycle.directory.identity else {
                throw MaintenanceFailure("Invalid maintenance preparation.")
            }
            let data = try AnchoredDirectory(dataURL, expected: request.data)
            try data.requirePrivateOwner()
            try request.bundle.validate()
            try channel.send(.ready(nonce))
            guard case .commit(let shutdown)? = try channel.receive(timeout: 90), shutdown.succeeded else {
                throw MaintenanceFailure("Maintenance was not authorized by a successful component shutdown.")
            }
            try channel.send(.committed)
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
            try? channel.send(.failure(error.localizedDescription))
            throw error
        }
    }

    package static func runBounded(_ process: Process, timeout: TimeInterval, waitForExit: Bool = true) throws {
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        if process.standardInput == nil { process.standardInput = FileHandle.nullDevice }
        if process.standardOutput == nil { process.standardOutput = FileHandle.nullDevice }
        if process.standardError == nil { process.standardError = FileHandle.nullDevice }
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

}
