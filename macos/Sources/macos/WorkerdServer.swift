import Foundation
import Darwin

enum WorkerdPaths {
    static var executableURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/workerd") }
    static var configURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Worker/worker.bin") }
    static var assetsURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/compose-ui") }
    static var stateURL: URL { ExternalState.appDataURL.appendingPathComponent("workerd", isDirectory: true) }
    static let uiURL = URL(string: "http://127.0.0.1:8094/")!
}

enum WorkerdError: LocalizedError {
    case missingResource(String)
    case exited(Int32)
    case notReady
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .missingResource(let path): "Missing workerd resource: \(path)"
        case .exited(let status): "workerd exited (\(status)). Check System Logs; port 8094 or 5196 may already be in use."
        case .notReady: "workerd did not become ready at 127.0.0.1:8094."
        case .alreadyRunning: "Another launcher instance owns the workerd state directory."
        }
    }
}

/// Owns the release's single workerd process. No Docker connection is required
/// to start it or serve assets.
@MainActor
final class WorkerdServer {
    private let executableURL: URL
    private let configURL: URL
    private let assetsURL: URL
    private let stateURL: URL
    private let managementPort: UInt16
    private let routingPort: UInt16
    private let log: @MainActor @Sendable (String) -> Void
    private var process: Process?
    private var stopping = false
    private var lockDescriptor: Int32 = -1

    var isRunning: Bool { process?.isRunning == true }
    var uiURL: URL { URL(string: "http://127.0.0.1:\(managementPort)/")! }
    init(executableURL: URL = WorkerdPaths.executableURL, configURL: URL = WorkerdPaths.configURL,
         assetsURL: URL = WorkerdPaths.assetsURL, stateURL: URL = WorkerdPaths.stateURL,
         managementPort: UInt16 = 8094, routingPort: UInt16 = 5196,
         log: @escaping @MainActor @Sendable (String) -> Void = { ExternalState.shared.appendLog("workerd", $0) }) {
        self.executableURL = executableURL
        self.configURL = configURL
        self.assetsURL = assetsURL
        self.stateURL = stateURL
        self.managementPort = managementPort
        self.routingPort = routingPort
        self.log = log
    }

    func start(composeSocketURL: URL, routerSocketURL: URL) async throws {
        try Task.checkCancellation()
        if isRunning { return }
        for url in [executableURL, configURL, assetsURL.appendingPathComponent("index.html")] {
            guard FileManager.default.fileExists(atPath: url.path) else { throw WorkerdError.missingResource(url.path) }
        }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateURL.path)
        // An exited child may leave this instance's ownership lock held.
        if lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
        let descriptor = open(stateURL.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw WorkerdError.alreadyRunning }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw WorkerdError.alreadyRunning
        }
        lockDescriptor = descriptor
        var started = false
        defer {
            if !started && lockDescriptor >= 0 { close(lockDescriptor); lockDescriptor = -1 }
        }
        let child = Process()
        child.executableURL = executableURL
        child.currentDirectoryURL = stateURL
        child.arguments = ["serve", "--binary", configURL.path,
            "--socket-addr", "management=127.0.0.1:\(managementPort)",
            "--socket-addr", "ingest=127.0.0.1:\(routingPort)",
            "--directory-path", "assets=\(assetsURL.path)",
            "--external-addr", "compose=unix:\(composeSocketURL.path)",
            "--external-addr", "router=unix:\(routerSocketURL.path)"]
        // No inherited inspector flags, npm paths, or proxy settings.
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
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
                guard let self, self.process === child, !self.stopping else { return }
                log("workerd exited unexpectedly (\(child.terminationStatus)); it will be restarted.")
            }
        }
        stopping = false
        do { try child.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw WorkerdError.exited(child.terminationStatus) }
                var request = URLRequest(url: uiURL, timeoutInterval: 1)
                request.setValue("127.0.0.1:8094", forHTTPHeaderField: "Host")
                if let (data, response) = try? await session.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                    try Task.checkCancellation()
                    guard child.isRunning else { throw WorkerdError.exited(child.terminationStatus) }
                    log("Compose UI ready at \(uiURL.absoluteString)")
                    started = true
                    return
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw WorkerdError.notReady
        } catch {
            await stop()
            throw error
        }
    }

    func requestStop() {
        stopping = true
        if let process, process.isRunning { process.terminate() }
    }

    func stop() async {
        requestStop()
        if let child = process {
            await Task.detached {
                let deadline = ContinuousClock.now + .seconds(5)
                while child.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
            }.value
            if process === child { process = nil }
        }
        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }
    }
}
