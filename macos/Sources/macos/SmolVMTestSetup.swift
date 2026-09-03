import Foundation

struct SmolVMTestResult: Sendable {
    let machineName: String
    let dockerSocketURL: URL
}

enum SmolVMTestSetup {
    static let machineName = "xe-launcher-smolvm-test-compose-1"
    static let dockerSocketURL = SmolVMPaths.socketsURL.appendingPathComponent("test-compose-1-docker.sock")

    static func start() async throws -> SmolVMTestResult {
        let client = SmolVMClient.shared
        let machines = try await client.listMachines()
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
                    "dev.xe.computer.purpose": "embedding-test",
                    "dev.xe.computer.smolvm-release": "v1.13.0-compose_1",
                ]
            )
            try await client.createMachine(spec)
        } else if existing?.isRunning == false {
            removeStaleSocketIfPresent()
        }

        if existing?.isRunning != true {
            try await client.startMachine(named: machineName)
        }

        for _ in 0..<360 {
            if FileManager.default.fileExists(atPath: dockerSocketURL.path) {
                return SmolVMTestResult(machineName: machineName, dockerSocketURL: dockerSocketURL)
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw SmolVMTestError.dockerSocketUnavailable(dockerSocketURL.path)
    }

    private static func removeStaleSocketIfPresent() {
        guard FileManager.default.fileExists(atPath: dockerSocketURL.path) else { return }
        try? FileManager.default.removeItem(at: dockerSocketURL)
    }
}

enum SmolVMTestError: LocalizedError, Sendable {
    case dockerSocketUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .dockerSocketUnavailable(let path):
            return "The test VM started, but its Docker socket did not appear at \(path)."
        }
    }
}
