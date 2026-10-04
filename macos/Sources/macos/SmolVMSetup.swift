import Foundation

struct SmolVMStartupResult: Sendable {
    let machineName: String
    let dockerSocketURL: URL
}

enum SmolVMSetup {
    static let machineName = "xe-launcher"
    static let dockerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("docker.sock")
    static let routerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("workerd.sock")
    static let guestStacksDirectory = "/stacks"

    static var stacksURL: URL {
        let configured = ExternalState.shared.stringSetting("compose_storage_path")
        return (configured.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? ComposeServerPaths.stacksURL)
            .resolvingSymlinksInPath()
    }

    static var resources: ContainerVMResources { ContainerVMResources(settings: ExternalState.shared.settings.rawData) }
    static var memoryMiB: UInt32 { resources.memoryMiB }

    static func start(virtualizationAvailable: Bool = VirtualizationSupport.isAvailable) async throws -> SmolVMStartupResult {
        try Task.checkCancellation()
        guard virtualizationAvailable else { throw SmolVMSetupError.virtualizationUnavailable }
        let client = SmolVMClient.shared
        let configuredResources = resources
        let stacksVolume = "\(stacksURL.path):\(guestStacksDirectory):rw"
        let machines = try await client.listMachines()
        try Task.checkCancellation()
        let existing = machines.first { $0.name == machineName }
        try await GuestRouter.shared.prepare()

        if existing != nil {
            // Restart a surviving VM with the runtime and mounts owned by this app.
            try await client.stopMachine(named: machineName)
            removeStaleSocketIfPresent()
        }
        try Task.checkCancellation()
        let currentDiskGiB = existing != nil
            ? try await client.machineStatus(named: machineName).storageGiB : nil
        let diskGiB = configuredResources.diskGiB(preserving: currentDiskGiB)
        let dockerConfigurationVolume = try DockerDaemonConfiguration.prepare(
            in: SmolVMPaths.dataURL.appendingPathComponent("docker-config", isDirectory: true),
            diskGiB: diskGiB
        )

        if existing == nil {
            removeStaleSocketIfPresent()
            let spec = SmolVMMachineSpec(
                name: machineName,
                artifactURL: SmolVMPaths.composeArtifactURL,
                memoryMiB: configuredResources.memoryMiB,
                cpus: configuredResources.cpus,
                storageGiB: diskGiB,
                networkBackend: "virtio-net",
                volumes: [
                    "\(GuestRouter.sharedURL.path):\(GuestRouter.guestDirectory):ro",
                    stacksVolume, dockerConfigurationVolume,
                ],
                exposedSockets: [
                    "/var/run/docker.sock:\(dockerSocketURL.path)",
                    "/run/xe-router/workerd.sock:\(routerSocketURL.path)",
                ],
                labels: [
                    "dev.xe.computer.owner": "launcher",
                    "dev.xe.computer.purpose": "runtime",
                    "dev.xe.computer.smolvm-release": "v1.16.2-compose_3",
                    GuestRouter.configurationLabel: GuestRouter.configurationVersion,
                ]
            )
            try await client.createMachine(spec)
        } else {
            try await client.updateMachine(
                named: machineName, memoryMiB: configuredResources.memoryMiB, cpus: configuredResources.cpus,
                storageGiB: diskGiB,
                volumes: [stacksVolume, dockerConfigurationVolume]
            )
        }

        try Task.checkCancellation()
        try await client.startMachine(named: machineName)
        try await waitForDocker()

        return SmolVMStartupResult(machineName: machineName, dockerSocketURL: dockerSocketURL)
    }

    private static func waitForDocker() async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if await UnixSocketHTTP.isReady(at: dockerSocketURL) {
                try Task.checkCancellation()
                return
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
