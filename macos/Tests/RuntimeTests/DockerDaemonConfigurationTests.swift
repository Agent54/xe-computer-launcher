import Foundation
import Testing
@testable import macos

struct DockerDaemonConfigurationTests {
    private func configuration(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func workspaceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/docker-config-tests/\(UUID().uuidString)")
    }

    private let cleanupArguments = ["/run", "/var/run", "-iname", "docker*.pid", "-delete"]

    /// Run the real shell wrapper against a workspace fixture. Only its absolute
    /// BusyBox and PID paths are redirected; no test can touch the host's /run.
    private func runStartupFind(
        in directory: URL, pidFile: URL, arguments: [String]
    ) throws -> (status: Int32, delegatedArguments: [String]) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let busybox = directory.appendingPathComponent("busybox")
        let trace = directory.appendingPathComponent("arguments")
        let wrapper = directory.appendingPathComponent("find")
        let stub = #"""
            #!/bin/sh
            printf '%s\0' "$@" > "$TEST_BUSYBOX_TRACE"
            case "$1" in
                rm) shift; exec /bin/rm "$@" ;;
                find) exit 23 ;;
                *) exit 99 ;;
            esac

            """#
        try Data(stub.utf8).write(to: busybox)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: busybox.path)
        let script = DockerDaemonConfiguration.startupFindScript
            .replacingOccurrences(of: "/bin/busybox", with: #""$TEST_BUSYBOX""#)
            .replacingOccurrences(of: DockerDaemonConfiguration.guestPIDFile, with: "$TEST_DOCKER_PID_FILE")
        try Data(script.utf8).write(to: wrapper)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TEST_BUSYBOX"] = busybox.path
        environment["TEST_BUSYBOX_TRACE"] = trace.path
        environment["TEST_DOCKER_PID_FILE"] = pidFile.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let delegated = (try? Data(contentsOf: trace))?
            .split(separator: 0, omittingEmptySubsequences: false).dropLast()
            .map { String(decoding: $0, as: UTF8.self) } ?? []
        return (process.terminationStatus, delegated)
    }

    @Test func startupCleanupRemovesOnlyTheConfiguredRegularPIDFile() throws {
        let directory = workspaceDirectory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: directory) }
        let run = directory.appendingPathComponent("run")
        let nested = run.appendingPathComponent("mounted-repository/nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let pid = run.appendingPathComponent("docker.pid")
        let other = run.appendingPathComponent("docker-other.pid")
        let nestedPID = nested.appendingPathComponent("docker.pid")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: pid)
        try sentinel.write(to: other)
        try sentinel.write(to: nestedPID)

        let result = try runStartupFind(in: directory, pidFile: pid, arguments: cleanupArguments)

        #expect(result.status == 0)
        #expect(result.delegatedArguments == ["rm", "-f", "--", pid.path])
        #expect(!fm.fileExists(atPath: pid.path))
        #expect(try Data(contentsOf: other) == sentinel)
        #expect(try Data(contentsOf: nestedPID) == sentinel)
    }

    @Test(arguments: ["missing", "symlink", "dangling-symlink", "directory"])
    func startupCleanupLeavesUnexpectedPIDEntriesAlone(kind: String) throws {
        let directory = workspaceDirectory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: directory) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let pid = directory.appendingPathComponent("docker.pid")
        let target = directory.appendingPathComponent("important-file")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: target)
        switch kind {
        case "symlink": try fm.createSymbolicLink(at: pid, withDestinationURL: target)
        case "dangling-symlink":
            try fm.createSymbolicLink(at: pid, withDestinationURL: directory.appendingPathComponent("absent"))
        case "directory":
            try fm.createDirectory(at: pid, withIntermediateDirectories: true)
            try sentinel.write(to: pid.appendingPathComponent("docker.pid"))
        default: break
        }

        let result = try runStartupFind(in: directory, pidFile: pid, arguments: cleanupArguments)

        #expect(result.status == 0)
        #expect(result.delegatedArguments.isEmpty)
        #expect(try Data(contentsOf: target) == sentinel)
        if kind == "symlink" || kind == "dangling-symlink" {
            #expect(try fm.destinationOfSymbolicLink(atPath: pid.path) != "")
        } else if kind == "directory" {
            #expect(try Data(contentsOf: pid.appendingPathComponent("docker.pid")) == sentinel)
        }
    }

    @Test(arguments: [
        [],
        ["/run", "/var/run", "-iname", "docker*.pid", "-print"],
        ["/run", "/var/run", "-iname", "other*.pid", "-delete"],
        ["/run", "/var/run", "-iname", "docker*.pid", "-delete", "-xdev"],
        ["a path with spaces", "-name", "literal $(command) `text`", ""],
    ])
    func otherFindCommandsKeepTheirArgumentsAndExitStatus(arguments: [String]) throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid = directory.appendingPathComponent("docker.pid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: pid)

        let result = try runStartupFind(in: directory, pidFile: pid, arguments: arguments)

        #expect(result.status == 23)
        #expect(result.delegatedArguments == ["find"] + arguments)
        #expect(try Data(contentsOf: pid) == sentinel)
    }

    @Test func mergesManagedDefaultsWithoutReplacingOtherHostSettings() throws {
        let current = Data(#"""
            {
              "data-root": "/storage/docker",
              "pidfile": "/storage/old-docker.pid",
              "restart": true,
              "builder": {
                "history": {"maxEntries": 100},
                "entitlements": {"network-host": false},
                "gc": {
                  "enabled": false,
                  "defaultKeepStorage": "20GB",
                  "defaultReservedSpace": "20GB",
                  "defaultMaxUsedSpace": "100GB",
                  "defaultMinFreeSpace": "20%",
                  "policy": [{"all": true, "reservedSpace": "30GB", "maxUsedSpace": "50GB"}]
                }
              },
              "log-driver": "json-file",
              "log-opts": {"labels": "project", "max-size": "100m"}
            }
            """#.utf8)
        let updated = try #require(try DockerDaemonConfiguration.updatedConfiguration(current, diskGiB: 20))
        let parsed = try configuration(updated)
        #expect(parsed["data-root"] as? String == "/storage/docker")
        #expect(parsed["pidfile"] as? String == DockerDaemonConfiguration.guestPIDFile)
        #expect(parsed["restart"] as? Bool == false)
        let builder = try #require(parsed["builder"] as? [String: Any])
        #expect(builder["history"] as? [String: Int] == ["maxEntries": 100])
        #expect(builder["entitlements"] as? [String: Bool] == ["network-host": false])
        let gc = try #require(builder["gc"] as? [String: Any])
        #expect(gc["enabled"] as? Bool == true)
        #expect(gc["defaultMaxUsedSpace"] as? String == "5GB")
        #expect(gc["defaultReservedSpace"] as? String == "0B")
        #expect(gc["defaultMinFreeSpace"] as? String == "1073741824")
        #expect(gc["defaultKeepStorage"] == nil)
        #expect(gc["policy"] == nil)
        #expect(try DockerDaemonConfiguration.updatedConfiguration(updated, diskGiB: 20) == nil)
        #expect(parsed["log-driver"] as? String == "local")
        #expect(parsed["log-opts"] as? [String: String] == ["max-size": "10m", "max-file": "3"])
    }

    @Test func preparesPrivateHostConfigurationAndReadOnlyMount() throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        #expect(volume == "\(directory.path):/etc/docker:ro")
        let file = directory.appendingPathComponent("daemon.json")
        let parsed = try configuration(Data(contentsOf: file))
        #expect(parsed["pidfile"] as? String == DockerDaemonConfiguration.guestPIDFile)
        #expect(parsed["restart"] as? Bool == false)
        #expect(parsed["log-driver"] as? String == "local")
        #expect(parsed["log-opts"] as? [String: String] == ["max-size": "10m", "max-file": "3"])
        let builder = try #require(parsed["builder"] as? [String: Any])
        let gc = try #require(builder["gc"] as? [String: Any])
        #expect(gc["enabled"] as? Bool == true)
        #expect(gc["defaultMaxUsedSpace"] as? String == "5GB")
        #expect(gc["defaultReservedSpace"] as? String == "0B")
        #expect(gc["defaultMinFreeSpace"] as? String == "1073741824")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(fileAttributes[.posixPermissions] as? Int == 0o600)
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)
        let find = directory.appendingPathComponent("startup/find")
        #expect(try String(contentsOf: find, encoding: .utf8) == DockerDaemonConfiguration.startupFindScript)
        #expect(FileManager.default.isExecutableFile(atPath: find.path))
    }

    @Test(arguments: ["[]", "null", "invalid", ""])
    func rejectsInvalidHostConfigurationWithoutOverwritingIt(json: String) throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("daemon.json")
        let original = Data(json.utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) {
            try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func preservesLiteralValuesInHostConfiguration() throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("daemon.json")
        let source = #"{"labels":["literal $(command) `text` 'quotes'"]}"#
        try Data(source.utf8).write(to: file)
        _ = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        let installed = try configuration(Data(contentsOf: file))
        #expect(installed["labels"] as? [String] == ["literal $(command) `text` 'quotes'"])
    }

    @Test func matchingHostConfigurationKeepsTheSameFile() throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstMount = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        let file = directory.appendingPathComponent("daemon.json")
        let original = try Data(contentsOf: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let secondMount = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(secondMount == firstMount)
        #expect(try Data(contentsOf: file) == original)
        #expect(before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
    }

    @Test func hostWriteFailureDoesNotReturnAMount() throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        #expect(throws: (any Error).self) {
            try DockerDaemonConfiguration.prepare(in: blocked, diskGiB: 20)
        }
        #expect(try Data(contentsOf: blocked) == Data("blocked".utf8))
    }

    @Test func freeDiskTargetUpdatesWhenDiskCapacityChanges() throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 20)
        _ = try DockerDaemonConfiguration.prepare(in: directory, diskGiB: 40)
        let parsed = try configuration(Data(contentsOf: directory.appendingPathComponent("daemon.json")))
        let builder = try #require(parsed["builder"] as? [String: Any])
        let gc = try #require(builder["gc"] as? [String: Any])
        #expect(gc["defaultMinFreeSpace"] as? String == "2147483648")
        #expect(gc["defaultMaxUsedSpace"] as? String == "5GB")
    }

    @Test(arguments: [0, UInt64.max] as [UInt64])
    func rejectsInvalidDiskCapacityWithoutWritingConfiguration(diskGiB: UInt64) throws {
        let directory = workspaceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: DockerDaemonConfigurationError.invalidCapacity) {
            try DockerDaemonConfiguration.prepare(in: directory, diskGiB: diskGiB)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
