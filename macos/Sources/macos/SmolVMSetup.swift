import Foundation

struct SmolVMStartupResult: Sendable {
    let machineName: String
    let dockerSocketURL: URL
}

enum SmolVMSetup {
    static let machineName = "xe-launcher"
    static let dockerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("docker.sock")

    static func start(virtualizationAvailable: Bool = VirtualizationSupport.isAvailable) async throws -> SmolVMStartupResult {
        try Task.checkCancellation()
        guard virtualizationAvailable else { throw SmolVMSetupError.virtualizationUnavailable }
        let client = SmolVMClient.shared
        let machines = try await client.listMachines()
        try Task.checkCancellation()
        let existing = machines.first { $0.name == machineName }

        if existing == nil {
            removeStaleSocketIfPresent()
            let spec = SmolVMMachineSpec(
                name: machineName,
                artifactURL: SmolVMPaths.composeArtifactURL,
                networkBackend: "virtio-net",
                exposedSockets: [
                    "/var/run/docker.sock:\(dockerSocketURL.path)"
                ],
                labels: [
                    "dev.xe.computer.owner": "launcher",
                    "dev.xe.computer.purpose": "runtime",
                    "dev.xe.computer.smolvm-release": "v1.13.0-compose_1",
                ]
            )
            try await client.createMachine(spec)
        } else if existing?.isRunning == false {
            removeStaleSocketIfPresent()
        }

        if existing?.isRunning != true {
            try Task.checkCancellation()
            try await client.startMachine(named: machineName)
        }

        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if await UnixSocketHTTP.isReady(at: dockerSocketURL) {
                try Task.checkCancellation()
                return SmolVMStartupResult(machineName: machineName, dockerSocketURL: dockerSocketURL)
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw SmolVMSetupError.dockerSocketUnavailable(dockerSocketURL.path)
    }

    private static func removeStaleSocketIfPresent() {
        guard FileManager.default.fileExists(atPath: dockerSocketURL.path) else { return }
        try? FileManager.default.removeItem(at: dockerSocketURL)
    }
}

enum SmolVMSetupError: LocalizedError, Sendable {
    case virtualizationUnavailable
    case dockerSocketUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .virtualizationUnavailable:
            return VirtualizationSupport.unavailableWarning
        case .dockerSocketUnavailable(let path):
            return "SmolVM started, but its Docker API did not become ready at \(path)."
        }
    }
}
