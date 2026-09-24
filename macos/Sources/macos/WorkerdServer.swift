import Foundation
import Darwin

enum WorkerdPaths {
    static var executableURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/workerd") }
    static var configURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Worker/config.capnp") }
    static var portHelperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/port-helper") }
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
        case .exited(let status): "workerd exited (\(status)). Check System Logs; a configured listener port may already be in use."
        case .notReady: "workerd did not become ready at 127.0.0.1:8094."
        case .alreadyRunning: "Another launcher instance owns the workerd state directory."
        }
    }
}

/// Owns the Workerd process, including its public router and private HTTPS
/// socket. No Docker connection is required to serve the Compose UI.
@MainActor
final class WorkerdServer {
    private let executableURL: URL
    private let configURL: URL
    private let portHelperURL: URL
    private let assetsURL: URL
    private let stateURL: URL
    private let runtimeStatusURL: URL
    private let managementPort: UInt16
    private let routingPort: UInt16
    private let tlsPort: UInt16
    private let acquirePrivilegedSockets: @Sendable () async throws -> PrivilegedPortSockets
    private let log: @MainActor @Sendable (String) -> Void
    private var process: Process?
    private var stopTask: Task<Void, Never>?
    private var stopping = false
    private var lockDescriptor: Int32 = -1
    private(set) var servingStandardPorts = false

    var isRunning: Bool { process?.isRunning == true }
    var usesStandardPorts: Bool { routingPort == WorkerdPorts.standardHTTP && tlsPort == WorkerdPorts.standardHTTPS }
    var processIdentifier: pid_t? { process?.processIdentifier }
    var uiURL: URL { URL(string: "http://127.0.0.1:\(managementPort)/")! }
    init(executableURL: URL = WorkerdPaths.executableURL, configURL: URL = WorkerdPaths.configURL,
         portHelperURL: URL = WorkerdPaths.portHelperURL,
         assetsURL: URL = WorkerdPaths.assetsURL, stateURL: URL = WorkerdPaths.stateURL,
         runtimeStatusURL: URL = ContainerRuntimeStatusStore.directoryURL,
         managementPort: UInt16 = 8094, routingPort: UInt16 = WorkerdPorts.defaultHTTP,
         tlsPort: UInt16 = WorkerdPorts.defaultHTTPS,
         acquirePrivilegedSockets: @escaping @Sendable () async throws -> PrivilegedPortSockets = { try await PrivilegedPortService.acquire() },
         log: @escaping @MainActor @Sendable (String) -> Void = { ExternalState.shared.appendLog("workerd", $0) }) {
        self.executableURL = executableURL
        self.configURL = configURL
        self.portHelperURL = portHelperURL
        self.assetsURL = assetsURL
        self.stateURL = stateURL
        self.runtimeStatusURL = runtimeStatusURL
        self.managementPort = managementPort
        self.routingPort = routingPort
        self.tlsPort = tlsPort
        self.acquirePrivilegedSockets = acquirePrivilegedSockets
        self.log = log
    }

    func start(composeSocketURL: URL, routerSocketURL: URL) async throws {
        try Task.checkCancellation()
        if let stopTask { await stopTask.value; self.stopTask = nil }
        if isRunning { return }
        if process != nil { await stop() }
        if let stopTask { await stopTask.value; self.stopTask = nil }
        stopping = false
        for url in [executableURL, configURL, assetsURL.appendingPathComponent("index.html")] {
            guard FileManager.default.fileExists(atPath: url.path) else { throw WorkerdError.missingResource(url.path) }
        }
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: runtimeStatusURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
        let state = stateURL
        let source = configURL
        let prepared = try await Task.detached(priority: .userInitiated) {
            let certificate = try LocalTLSCertificate.prepare(stateURL: state)
            let sources = try FileManager.default.contentsOfDirectory(at: source.deletingLastPathComponent(),
                                                                      includingPropertiesForKeys: nil)
            for file in sources where file.pathExtension == "js" || file.lastPathComponent == "config.capnp" {
                let contents = try Data(contentsOf: file)
                try contents.write(to: certificate.directoryURL.appendingPathComponent(file.lastPathComponent), options: .atomic)
            }
            return certificate
        }.value
        if prepared.createdCertificate {
            log("Local Compose UI certificate authority created at \(prepared.certificateURL.path). Trust this certificate in Keychain Access to avoid browser warnings for compose-ui.localhost and HTTP apps on HTTPS.")
        }
        let uiSocketURL = stateURL.appendingPathComponent("u-\(UUID().uuidString.prefix(8)).sock")
        let needsPrivilegedPorts = usesStandardPorts
        var privilegedSockets: PrivilegedPortSockets?
        if needsPrivilegedPorts {
            do { privilegedSockets = try await acquirePrivilegedSockets() }
            catch { log("Warning: \(error.localizedDescription) App routing on standard ports is unavailable; Xe Launcher will retry automatically.") }
        }
        if privilegedSockets != nil && !FileManager.default.isExecutableFile(atPath: portHelperURL.path) {
            log("Warning: Missing port-helper executable at \(portHelperURL.path); standard app ports are unavailable.")
            privilegedSockets = nil
        }
        let appPorts = try JSONSerialization.data(withJSONObject: [
            "http": Int(routingPort), "https": Int(tlsPort),
            "publicHttpReady": !needsPrivilegedPorts || privilegedSockets != nil,
        ], options: [.sortedKeys])
        try appPorts.write(to: runtimeStatusURL.appendingPathComponent("app-ports.json"), options: .atomic)
        if stopping { await stop(); throw CancellationError() }
        let child = Process()
        child.executableURL = privilegedSockets == nil ? executableURL : portHelperURL
        child.currentDirectoryURL = stateURL
        // FIXME(multi-user): Loopback TCP listeners are machine-wide, including
        // the privileged sockets. Block connections from other macOS accounts
        // before serving this user's Compose UI/API or apps; Host/Origin checks
        // and the helper's caller check do not authenticate individual clients.
        var workerArguments = ["serve", "--experimental", prepared.directoryURL.appendingPathComponent("config.capnp").path,
            "--socket-addr", "management=127.0.0.1:\(managementPort)",
            "--socket-addr", "ui-https=unix:\(uiSocketURL.path)",
            "--directory-path", "assets=\(assetsURL.path)",
            "--directory-path", "status=\(runtimeStatusURL.path)",
            "--external-addr", "compose=unix:\(composeSocketURL.path)",
            "--external-addr", "router=unix:\(routerSocketURL.path)",
            "--external-addr", "ui-tls=unix:\(uiSocketURL.path)"]
        if privilegedSockets != nil {
            workerArguments += ["--socket-fd", "ingest=3"]
        } else {
            workerArguments += ["--socket-addr", "ingest=127.0.0.1:\(needsPrivilegedPorts ? 0 : routingPort)"]
        }
        if privilegedSockets != nil {
            workerArguments += ["--socket-fd", "tls=4"]
        } else {
            workerArguments += ["--socket-addr", "tls=127.0.0.1:\(needsPrivilegedPorts ? 0 : tlsPort)"]
        }
        child.arguments = privilegedSockets == nil ? workerArguments : ["--exec-workerd", executableURL.path] + workerArguments
        // No inherited inspector flags, npm paths, or proxy settings.
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.standardInput = privilegedSockets?.http ?? FileHandle.nullDevice
        let output = Pipe()
        child.standardOutput = privilegedSockets?.https ?? output
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
                await self.stop()
            }
        }
        do { try child.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            await stop()
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
                    if routingPort != 80 || privilegedSockets != nil {
                        let httpPort = routingPort == 80 ? "" : ":\(routingPort)"
                        log("Compose UI ready at http://compose-ui.localhost\(httpPort)/")
                    }
                    if tlsPort != 443 || privilegedSockets != nil {
                        let httpsPort = tlsPort == 443 ? "" : ":\(tlsPort)"
                        log("Compose UI HTTPS ready at https://compose-ui.localhost\(httpsPort)/")
                    }
                    servingStandardPorts = needsPrivilegedPorts && privilegedSockets != nil
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
        if let stopTask { await stopTask.value; return }
        requestStop()
        servingStandardPorts = false
        let child = process
        let descriptor = lockDescriptor
        let log = self.log
        process = nil
        lockDescriptor = -1
        let cleanup = Task {
            if let child {
                let forced = await Task.detached {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while child.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                    let forced = child.isRunning
                    if forced { kill(child.processIdentifier, SIGKILL) }
                    child.waitUntilExit()
                    return forced
                }.value
                if forced { log("workerd did not exit after 5.0s; sent SIGKILL.") }
            }
            if descriptor >= 0 { close(descriptor) }
        }
        stopTask = cleanup
        await cleanup.value
    }
}
