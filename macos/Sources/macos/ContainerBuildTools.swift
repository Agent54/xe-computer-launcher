import CryptoKit
import Foundation
import Darwin

/// Versioned guest executables let existing VMs upgrade without replacing their
/// storage or overlay disks. The host only runs the native Buildx client.
enum ContainerBuildTools {
    static let builderName = "xe"
    static let guestDirectory = "/opt/xe/container-tools"
    static let guestClientDirectory = "/storage/xe-build-client"
    static var resourceURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ContainerTools")
    }
    static var sharedURL: URL { SmolVMPaths.dataURL.appendingPathComponent("container-tools") }
    static var clientURL: URL { ExternalState.appDataURL.appendingPathComponent("docker-client") }

    static func prepareGuest() throws -> (volume: String, environment: [String], path: String) {
        let fm = FileManager.default
        let manifest = try Data(contentsOf: resourceURL.appendingPathComponent("checksums.txt"))
        let revision = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        let releases = sharedURL.appendingPathComponent("releases")
        try fm.createDirectory(at: releases, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = releases.appendingPathComponent(revision)
        if !fm.fileExists(atPath: destination.path) {
            let staging = releases.appendingPathComponent(UUID().uuidString)
            do {
                try fm.copyItem(at: resourceURL, to: staging)
                try fm.moveItem(at: staging, to: destination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
        let path = "\(guestDirectory)/releases/\(revision)"
        return (
            "\(sharedURL.path):\(guestDirectory):ro",
            ["PATH=/etc/docker/startup:\(path)/docker:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
             "XE_CONTAINER_TOOLS=\(path)", "DOCKER_CONFIG=\(guestClientDirectory)"],
            path
        )
    }

    static func configuration(_ source: Data, pluginDirectory: URL) throws -> Data {
        guard var config = try JSONSerialization.jsonObject(with: source) as? [String: Any] else {
            throw Failure("Docker client configuration must be a JSON object.")
        }
        // Keep credentials and proxies, but select only the app-owned plugin.
        // Never modify ~/.docker/config.json or the user's selected builder.
        config["cliPluginsExtraDirs"] = [pluginDirectory.path]
        config.removeValue(forKey: "currentContext")
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    static func prepareHost(
        pluginURL: URL, resourceURL: URL = resourceURL, clientURL: URL = clientURL,
        sourceConfigURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".docker/config.json"),
        dockerSocketURL: URL
    ) async throws -> [String: String] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: pluginURL.path) else {
            throw Failure("The bundled Buildx client is missing at \(pluginURL.path). Reinstall Xe Launcher. Classic builds are disabled.")
        }
        let values = try lockValues(at: resourceURL.appendingPathComponent("ContainerTools.lock"))
        guard let version = values["BUILDX_VERSION"] else {
            throw Failure("The bundled builder version manifest is incomplete.")
        }
        try fm.createDirectory(at: clientURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source: Data
        do { source = try Data(contentsOf: sourceConfigURL) }
        catch CocoaError.fileReadNoSuchFile { source = Data("{}".utf8) }
        let configURL = clientURL.appendingPathComponent("config.json")
        try configuration(source, pluginDirectory: pluginURL.deletingLastPathComponent()).write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let environment = [
            "DOCKER_HOST": "unix://\(dockerSocketURL.path)",
            "DOCKER_CONFIG": clientURL.path,
            "DOCKER_BUILDKIT": "1",
            "BUILDX_BUILDER": builderName,
            "BUILDX_CONFIG": clientURL.appendingPathComponent("buildx").path,
        ]
        let actual = try await run(pluginURL, ["version"], environment: environment, directory: clientURL)
        guard actual.contains("v\(version) ") else { throw Failure("Unexpected bundled Buildx version: \(actual)") }
        return environment
    }

    /// Buildx create contacts Docker. Keep it in VM startup, so Compose's
    /// management API can still start while Docker is down or restarting.
    static func registerHostBuilder(dockerSocketURL: URL) async throws {
        let pluginURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cli-plugins/docker-buildx")
        let environment = try await prepareHost(pluginURL: pluginURL, dockerSocketURL: dockerSocketURL)
        let values = try lockValues(at: resourceURL.appendingPathComponent("ContainerTools.lock"))
        guard let image = values["BUILDKIT_IMAGE_ID"] else { throw Failure("Missing BuildKit image identity.") }
        let fm = FileManager.default
        let append = fm.fileExists(atPath: clientURL.appendingPathComponent("buildx/instances/xe").path) ? ["--append"] : []
        _ = try await run(pluginURL, [
            "create", "--name", builderName, "--node", "xe0", "--driver", "docker-container",
            "--driver-opt", "image=\(image)", "--driver-opt", "default-load=true",
            "--buildkitd-config", resourceURL.appendingPathComponent("buildkitd.toml").path,
            "unix://\(dockerSocketURL.path)",
        ] + append, environment: environment, directory: clientURL)
    }

    static func lockValues(at url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        })
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String], directory: URL) async throws -> String {
        let output = directory.appendingPathComponent("command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure("Could not create the builder command log.")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging([
            "HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]) { current, _ in current }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let observer = ProcessExitObserver()
        observer.install(on: process)
        try process.run()
        let timeout = Task {
            try await Task.sleep(for: .seconds(15))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { timeout.cancel() }
        await withTaskCancellationHandler {
            await observer.wait()
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try Task.checkCancellation()
        try handle.close()
        let result = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw Failure("Buildx setup failed: \(result)") }
        return result
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
