import Foundation
import Darwin

enum ComposeServerPaths {
    static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/docker-compose")
    }

    static var stacksURL: URL {
        ExternalState.appDataURL.appendingPathComponent("stacks", isDirectory: true)
    }
}

enum ComposeServerError: LocalizedError {
    case executableMissing(String)
    case socketPathTooLong(String)
    case alreadyListening(String)
    case exited(Int32)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path): return "The bundled Compose server is missing at \(path)."
        case .socketPathTooLong(let path): return "The Compose server socket path is too long: \(path)"
        case .alreadyListening(let path): return "Another Compose server is already listening at \(path)."
        case .exited(let code): return "Compose server exited with code \(code). See the Compose server logs."
        case .notReady(let path): return "Compose server did not become ready at \(path)."
        }
    }
}

/// Owns the host process for this launcher's lifetime. Docker runs in SmolVM;
/// Compose reads projects on the host and connects through its exposed socket.
@MainActor
final class ComposeServer {
    private let executableURL: URL
    private let stacksURL: URL
    private let log: @MainActor @Sendable (String) -> Void
    private var process: Process?
    private var stopping = false

    var socketURL: URL { stacksURL.appendingPathComponent("compose.sock") }
    var isRunning: Bool { process?.isRunning == true }

    init(
        executableURL: URL = ComposeServerPaths.executableURL,
        stacksURL: URL = ComposeServerPaths.stacksURL,
        log: @escaping @MainActor @Sendable (String) -> Void = {
            ExternalState.shared.appendLog("compose", $0)
        }
    ) {
        self.executableURL = executableURL
        self.stacksURL = stacksURL
        self.log = log
    }

    @discardableResult
    func start(dockerSocketURL: URL) async throws -> URL {
        try Task.checkCancellation()
        if isRunning { return socketURL }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ComposeServerError.executableMissing(executableURL.path)
        }
        // sockaddr_un.sun_path has room for 104 bytes including its terminator.
        guard socketURL.path.utf8.count < 104 else {
            throw ComposeServerError.socketPathTooLong(socketURL.path)
        }
        try FileManager.default.createDirectory(
            at: stacksURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // The fork unlinks existing socket files. Do not let it replace a live
        // listener owned by another launcher instance.
        if await UnixSocketHTTP.isReady(at: socketURL, path: "/") {
            throw ComposeServerError.alreadyListening(socketURL.path)
        }
        try Task.checkCancellation()

        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["serve", stacksURL.path]
        child.currentDirectoryURL = stacksURL
        var environment = ProcessInfo.processInfo.environment
        // DOCKER_CONTEXT takes precedence over DOCKER_HOST. Never inherit a
        // user's remote daemon or TLS settings for this local SmolVM service.
        for key in ["DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION", "__CFBundleIdentifier"] {
            environment.removeValue(forKey: key)
        }
        environment["DOCKER_HOST"] = "unix://\(dockerSocketURL.path)"
        environment["HOME"] = NSHomeDirectory()
        environment["STACKS_PATH"] = stacksURL.path
        environment["HOST_UID"] = String(getuid())
        environment["HOST_GID"] = String(getgid())
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice

        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        let log = self.log
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                for line in text.split(whereSeparator: \.isNewline) { log(String(line)) }
            }
        }
        child.terminationHandler = { [weak self] child in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.process === child else { return }
                if !self.stopping { log("Compose server exited unexpectedly (code=\(child.terminationStatus)).") }
            }
        }

        stopping = false
        do {
            try child.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw ComposeServerError.exited(child.terminationStatus) }
                if await UnixSocketHTTP.isReady(at: socketURL, path: "/") {
                    try Task.checkCancellation()
                    guard child.isRunning else { throw ComposeServerError.exited(child.terminationStatus) }
                    log("Compose API ready at unix://\(socketURL.path), Docker host unix://\(dockerSocketURL.path)")
                    return socketURL
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw ComposeServerError.notReady(socketURL.path)
        } catch {
            await stop()
            throw error
        }
    }

    func requestStop() {
        guard let process, process.isRunning, !stopping else { return }
        stopping = true
        process.terminate()
    }

    func stop() async {
        guard let child = process else { return }
        requestStop()
        // The fork allows five seconds for HTTP shutdown. Allow some margin
        // before forcing this owned child to exit, including during updates.
        await Task.detached {
            let deadline = ContinuousClock.now + .seconds(8)
            while child.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }.value
        if process === child { process = nil }
    }
}
