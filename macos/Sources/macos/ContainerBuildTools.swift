import Foundation
import Darwin

/// Host client configuration only. Guest engines belong to the SmolVM image.
enum ContainerBuildTools {
    static let builderName = "xe"
    static var resourceURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ContainerTools")
    }
    static var clientURL: URL { ExternalState.appDataURL.appendingPathComponent("docker-client") }

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
            "XE_SMOLVM_DATA_DIR": RuntimeSocketPaths.shared.smolDataURL.path,
            "XE_SMOLVM_HOME": RuntimeSocketPaths.shared.smolDataURL.appendingPathComponent("runtime-home").path,
            "XE_SMOLVM_MACHINE": SmolVMSetup.machineName,
        ]
        let actual = try await run(pluginURL, ["version"], environment: environment, directory: clientURL)
        guard actual.contains("v\(version) ") else { throw Failure("Unexpected bundled Buildx version: \(actual)") }
        return environment
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
