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

    @Test func mergesManagedDefaultsWithoutReplacingOtherHostSettings() throws {
        let current = Data(#"""
            {
              "data-root": "/storage/docker",
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
