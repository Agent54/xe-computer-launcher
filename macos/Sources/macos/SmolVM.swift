import Foundation
import Darwin

struct SmolVMCommandResult: Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

struct SmolVMMachine: Decodable, Sendable {
    let name: String
    let state: String
    let labels: [String: String]?
    let memory: SmolVMMemoryStatus?
    let workload: SmolVMWorkloadStatus?

    var isRunning: Bool {
        state.caseInsensitiveCompare("running") == .orderedSame
    }
}

struct SmolVMMemoryStatus: Decodable, Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let freeBytes: UInt64
    let buffersBytes: UInt64
    let cachedBytes: UInt64
    let oomKillCount: UInt64?

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case availableBytes = "available_bytes"
        case freeBytes = "free_bytes"
        case buffersBytes = "buffers_bytes"
        case cachedBytes = "cached_bytes"
        case oomKillCount = "oom_kill_count"
    }
}

struct SmolVMWorkloadStatus: Decodable, Sendable {
    let state: String
    let lastExitCode: Int32?
    let lastExitReason: String?
    let oomKilled: Bool?

    enum CodingKeys: String, CodingKey {
        case state
        case lastExitCode = "last_exit_code"
        case lastExitReason = "last_exit_reason"
        case oomKilled = "oom_killed"
    }
}

struct SmolVMMachineSpec: Sendable {
    let name: String
    let artifactURL: URL
    var memoryMiB: UInt32? = nil
    var networkBackend: String? = nil
    var volumes: [String] = []
    var ports: [String] = []
    var exposedSockets: [String] = []
    var mountedSockets: [String] = []
    var labels: [String: String] = [:]
}

enum SmolVMPaths {
    static var runtimeURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SmolRuntime", isDirectory: true)
    }

    static var guestRuntimeURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SmolRuntime", isDirectory: true)
    }

    static var dataURL: URL {
        ExternalState.appDataURL.appendingPathComponent("smol", isDirectory: true)
    }

    static var socketsURL: URL {
        dataURL.appendingPathComponent("sockets", isDirectory: true)
    }

    static var runtimeHomeURL: URL {
        dataURL.appendingPathComponent("runtime-home", isDirectory: true)
    }

    static var composeArtifactURL: URL {
        guestRuntimeURL.appendingPathComponent("docker-compose.smolmachine")
    }
}

enum SmolVMError: LocalizedError, Sendable {
    case runtimeMissing(String)
    case statePathTooLong(String)
    case commandLaunchFailed(String)
    case commandFailed(arguments: [String], exitCode: Int32, detail: String)
    case invalidMachineList(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing(let path):
            return "The embedded SmolVM runtime is missing at \(path)."
        case .statePathTooLong(let path):
            return "The SmolVM state path is too long for Unix sockets: \(path)"
        case .commandLaunchFailed(let detail):
            return "SmolVM could not be launched: \(detail)"
        case .commandFailed(let arguments, let exitCode, let detail):
            let command = (["smolvm-bin"] + arguments).joined(separator: " ")
            return "SmolVM exited with code \(exitCode).\n\n\(command)\n\n\(detail)"
        case .invalidMachineList(let detail):
            return "SmolVM returned an invalid machine list: \(detail)"
        }
    }
}

/// Minimal serialized Swift API for the embedded SmolVM command-line runtime.
actor SmolVMClient {
    static let shared = SmolVMClient()

    private let fileManager = FileManager.default
    private let runtimeURL: URL
    private let dataURL: URL
    private var activeProcess: Process?

    init(runtimeURL: URL = SmolVMPaths.runtimeURL, dataURL: URL = SmolVMPaths.dataURL) {
        self.runtimeURL = runtimeURL
        self.dataURL = dataURL
    }

    func listMachines() async throws -> [SmolVMMachine] {
        let result = try await invoke(["machine", "ls", "--json"])
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw SmolVMError.invalidMachineList("output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode([SmolVMMachine].self, from: data)
        } catch {
            throw SmolVMError.invalidMachineList(error.localizedDescription)
        }
    }

    func createMachine(_ spec: SmolVMMachineSpec) async throws {
        var arguments = [
            "machine", "create",
            "--name", spec.name,
            "--from", spec.artifactURL.path,
        ]
        if let memoryMiB = spec.memoryMiB {
            arguments += ["--mem", String(memoryMiB)]
        }
        if let networkBackend = spec.networkBackend {
            arguments += ["--net-backend", networkBackend]
        }
        for volume in spec.volumes {
            arguments += ["--volume", volume]
        }
        for port in spec.ports {
            arguments += ["--port", port]
        }
        for socket in spec.exposedSockets {
            arguments += ["--expose-socket", socket]
        }
        for socket in spec.mountedSockets {
            arguments += ["--mount-socket", socket]
        }
        for (key, value) in spec.labels.sorted(by: { $0.key < $1.key }) {
            arguments += ["--label", "\(key)=\(value)"]
        }
        _ = try await invoke(arguments)
    }

    func updateMachine(named name: String, memoryMiB: UInt32) async throws {
        _ = try await invoke(["machine", "update", "--name", name, "--mem", String(memoryMiB)])
    }

    func machineStatus(named name: String) async throws -> SmolVMMachine {
        let result = try await invoke(["machine", "status", "--name", name, "--json"])
        guard let data = result.standardOutput.data(using: .utf8) else {
            throw SmolVMError.invalidMachineList("status output was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(SmolVMMachine.self, from: data)
        } catch {
            throw SmolVMError.invalidMachineList(error.localizedDescription)
        }
    }

    func startMachine(named name: String) async throws {
        _ = try await invoke(["machine", "start", "--name", name])
    }

    func stopMachine(named name: String) async throws {
        _ = try await invoke(["machine", "stop", "--name", name])
    }

    func execute(in name: String, command: [String], detached: Bool = false) async throws -> SmolVMCommandResult {
        try await invoke(["machine", "exec", "--name", name] + (detached ? ["--detach"] : []) + ["--"] + command)
    }

    @discardableResult
    func invoke(_ arguments: [String]) async throws -> SmolVMCommandResult {
        while activeProcess != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
        try prepareStateDirectories()

        let executableURL = runtimeURL.appendingPathComponent("smolvm-bin")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw SmolVMError.runtimeMissing(executableURL.path)
        }

        let temporaryDirectory = dataURL.appendingPathComponent("tmp", isDirectory: true)
        let commandID = UUID().uuidString
        let outputURL = temporaryDirectory.appendingPathComponent("\(commandID).stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("\(commandID).stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw SmolVMError.commandLaunchFailed("could not create command output files")
        }
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = dataURL
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.environment = [
            "HOME": SmolVMPaths.runtimeHomeURL.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": temporaryDirectory.path,
            "SMOLVM_DATA_DIR": dataURL.path,
            "SMOLVM_LIB_DIR": runtimeURL.appendingPathComponent("lib", isDirectory: true).path,
            "SMOLVM_AGENT_ROOTFS_TAR": SmolVMPaths.guestRuntimeURL.appendingPathComponent("agent-rootfs.tar").path,
            "DYLD_LIBRARY_PATH": runtimeURL.appendingPathComponent("lib", isDirectory: true).path,
        ]

        do {
            try process.run()
        } catch {
            throw SmolVMError.commandLaunchFailed(error.localizedDescription)
        }
        activeProcess = process
        defer {
            if activeProcess === process { activeProcess = nil }
        }

        await withTaskCancellationHandler {
            await Task.detached {
                process.waitUntilExit()
            }.value
        } onCancel: {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        try Task.checkCancellation()

        try outputHandle.close()
        try errorHandle.close()
        let standardOutput = String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? ""
        let standardError = String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? ""
        let result = SmolVMCommandResult(
            standardOutput: standardOutput,
            standardError: standardError,
            exitCode: process.terminationStatus
        )

        guard result.exitCode == 0 else {
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                : standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SmolVMError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                detail: detail
            )
        }
        return result
    }

    private func prepareStateDirectories() throws {
        // SmolVM adds internal socket suffixes below this directory. Keep a
        // conservative margin under macOS's approximately 104-byte limit.
        guard dataURL.path.utf8.count <= 72 else {
            throw SmolVMError.statePathTooLong(dataURL.path)
        }

        for directory in [
            dataURL,
            dataURL.appendingPathComponent("tmp", isDirectory: true),
            SmolVMPaths.socketsURL,
            SmolVMPaths.runtimeHomeURL,
            SmolVMPaths.runtimeHomeURL.appendingPathComponent(".smolvm", isDirectory: true),
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let templateDirectory = SmolVMPaths.runtimeHomeURL.appendingPathComponent(".smolvm", isDirectory: true)
        for filename in ["storage-template.ext4.zst", "overlay-template.ext4.zst"] {
            let source = SmolVMPaths.guestRuntimeURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SmolVMError.runtimeMissing(source.path)
            }
            let destination = templateDirectory.appendingPathComponent(filename)
            if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination.path) {
                if existingTarget == source.path {
                    continue
                }
                try fileManager.removeItem(at: destination)
            }
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
            }
        }
    }
}
