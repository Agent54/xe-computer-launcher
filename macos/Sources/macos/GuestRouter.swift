import Foundation
import CryptoKit

/// Starts the guest workerd directly through SmolVM's detached exec API.
/// One process serves all application connections through the exposed socket.
actor GuestRouter {
    static let shared = GuestRouter()
    static let configurationLabel = "dev.xe.computer.guest-router"
    static let configurationVersion = "unix-v1"
    static let guestDirectory = "/opt/xe/guest-worker"
    static var resourceURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/GuestWorker", isDirectory: true)
    }
    static var sharedURL: URL {
        SmolVMPaths.dataURL.appendingPathComponent("guest-worker", isDirectory: true)
    }
    private var nextCheck = Date.distantPast
    private var deployed = false
    private var runtimeDirectory: String?

    func prepare() throws {
        guard runtimeDirectory == nil else { return }
        let fm = FileManager.default
        let manifest = Self.resourceURL.appendingPathComponent("checksums.txt")
        guard fm.fileExists(atPath: manifest.path) else { throw WorkerdError.missingResource(manifest.path) }
        let revision = SHA256.hash(data: try Data(contentsOf: manifest)).map { String(format: "%02x", $0) }.joined()
        let releases = Self.sharedURL.appendingPathComponent("releases", isDirectory: true)
        let destination = releases.appendingPathComponent(revision, isDirectory: true)
        try fm.createDirectory(at: releases, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: destination.path) {
            // Never overwrite executable/library files mapped by a running guest.
            let staging = releases.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.copyItem(at: Self.resourceURL, to: staging)
            for name in ["workerd", "lib/ld-linux-aarch64.so.1"] {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.appendingPathComponent(name).path)
            }
            try fm.moveItem(at: staging, to: destination)
        }
        runtimeDirectory = "\(Self.guestDirectory)/releases/\(revision)"
    }

    func reconcile() async throws {
        guard Date() >= nextCheck else { return }
        // Wait for discovery and for any legacy Docker-managed router to be
        // removable before claiming its socket. The host UI never waits here.
        guard await UnixSocketHTTP.isReady(at: SmolVMSetup.dockerSocketURL) else {
            deployed = false
            nextCheck = Date().addingTimeInterval(1)
            return
        }
        if deployed {
            if await UnixSocketHTTP.isReady(at: SmolVMSetup.routerSocketURL, path: "/__xe_router_health") {
                nextCheck = Date().addingTimeInterval(15)
                return
            }
        }
        let client = SmolVMClient.shared
        guard let machine = try await client.listMachines().first(where: { $0.name == SmolVMSetup.machineName }), machine.isRunning else {
            deployed = false
            nextCheck = Date().addingTimeInterval(1)
            return
        }
        guard machine.labels?[Self.configurationLabel] == Self.configurationVersion else {
            throw GuestRouterError.requiresSocketConfiguration
        }
        try prepare()
        guard let runtimeDirectory else { return }
        try Task.checkCancellation()
        _ = try await client.execute(in: machine.name, command: ["/bin/sh", "\(runtimeDirectory)/stop.sh"])
        try Task.checkCancellation()
        _ = try await client.execute(in: machine.name, command: ["/bin/sh", "\(runtimeDirectory)/run.sh"], detached: true)
        deployed = true
        nextCheck = Date().addingTimeInterval(15)
    }

    func reset() {
        deployed = false
        nextCheck = .distantPast
    }
}

enum GuestRouterError: LocalizedError {
    case requiresSocketConfiguration
    var errorDescription: String? {
        "This VM predates the guest router socket and resource mount. Its data has been kept intact. Recreate the VM before using application routing; Compose management remains available."
    }
}
