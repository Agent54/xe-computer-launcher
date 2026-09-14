import Foundation

struct SmolVMStartupResult: Sendable {
    let machineName: String
    let dockerSocketURL: URL
}

enum SmolVMSetup {
    static let machineName = "xe-launcher"
    static let dockerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("docker.sock")
    static let routerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("workerd.sock")

    static func start(virtualizationAvailable: Bool = VirtualizationSupport.isAvailable) async throws -> SmolVMStartupResult {
        try Task.checkCancellation()
        guard virtualizationAvailable else { throw SmolVMSetupError.virtualizationUnavailable }
        let client = SmolVMClient.shared
        let machines = try await client.listMachines()
        try Task.checkCancellation()
        let existing = machines.first { $0.name == machineName }
        try await GuestRouter.shared.prepare()

        if existing == nil {
            removeStaleSocketIfPresent()
            let spec = SmolVMMachineSpec(
                name: machineName,
                artifactURL: SmolVMPaths.composeArtifactURL,
                networkBackend: "virtio-net",
                volumes: ["\(GuestRouter.sharedURL.path):\(GuestRouter.guestDirectory):ro"],
                exposedSockets: [
                    "/var/run/docker.sock:\(dockerSocketURL.path)",
                    "/run/xe-router/workerd.sock:\(routerSocketURL.path)",
                ],
                labels: [
                    "dev.xe.computer.owner": "launcher",
                    "dev.xe.computer.purpose": "runtime",
                    "dev.xe.computer.smolvm-release": "v1.13.0-compose_1",
                    GuestRouter.configurationLabel: GuestRouter.configurationVersion,
                ]
            )
            try await client.createMachine(spec)
        } else {
            // The launcher owns this machine. A running instance here survived an
            // earlier launcher crash or predates lifecycle-managed shutdown, so
            // restart it with the runtime bundled in the current app.
            try await client.stopMachine(named: machineName)
            removeStaleSocketIfPresent()
        }

        try Task.checkCancellation()
        try await client.startMachine(named: machineName)

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

    static func stop() async throws {
        let client = SmolVMClient.shared
        let machineExists = try await client.listMachines().contains { $0.name == machineName }
        if machineExists {
            try await client.stopMachine(named: machineName)
        }
        removeStaleSocketIfPresent()
    }

    private static func removeStaleSocketIfPresent() {
        for socket in [dockerSocketURL, routerSocketURL] {
            guard FileManager.default.fileExists(atPath: socket.path) else { continue }
            try? FileManager.default.removeItem(at: socket)
        }
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
