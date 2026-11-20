import Foundation
import Testing
@testable import macos

struct VMImageTests {
    @Test func requiresOneValidBundledImageRevision() throws {
        let revision = String(repeating: "a", count: 64)
        let line = "XE_RUNTIME_INPUT_SHA256=\(revision)\n"
        #expect(try SmolVMSetup.imageRevision(from: line) == revision)
        for invalid in ["", line + line, "XE_RUNTIME_INPUT_SHA256=unknown\n",
                        "XE_RUNTIME_INPUT_SHA256=\(String(repeating: "g", count: 64))\n"] {
            #expect(throws: (any Error).self) { try SmolVMSetup.imageRevision(from: invalid) }
        }
    }

    private var macosURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func workspaceDirectory() -> URL {
        macosURL.appendingPathComponent(".build/image-tests/\(UUID().uuidString)")
    }

    /// Run the image's actual cleanup script with only its fixed PID path
    /// redirected to a workspace fixture. Never touch the host's /run.
    private func cleanup(in directory: URL, pidFile: URL) throws -> Int32 {
        let script = try String(contentsOf: macosURL.appendingPathComponent("Runtime/vm/cleanup-docker-pid.sh"), encoding: .utf8)
            .replacingOccurrences(of: "/run/docker.pid", with: #""$TEST_DOCKER_PID_FILE""#)
        let wrapper = directory.appendingPathComponent("cleanup.sh")
        try Data(script.utf8).write(to: wrapper)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path]
        process.environment = ["PATH": "/usr/bin:/bin", "TEST_DOCKER_PID_FILE": pidFile.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func cleanupRemovesOnlyTheConfiguredRegularPIDFile() throws {
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
        #expect(try cleanup(in: directory, pidFile: pid) == 0)
        #expect(!fm.fileExists(atPath: pid.path))
        #expect(try Data(contentsOf: other) == sentinel)
        #expect(try Data(contentsOf: nestedPID) == sentinel)
    }

    @Test(arguments: ["missing", "symlink", "dangling-symlink", "directory"])
    func cleanupLeavesUnexpectedPIDEntriesAlone(kind: String) throws {
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
        #expect(try cleanup(in: directory, pidFile: pid) == 0)
        #expect(try Data(contentsOf: target) == sentinel)
        if kind == "symlink" || kind == "dangling-symlink" {
            #expect(try fm.destinationOfSymbolicLink(atPath: pid.path) != "")
        } else if kind == "directory" {
            #expect(try Data(contentsOf: pid.appendingPathComponent("docker.pid")) == sentinel)
        }
    }

    @Test func imageDefaultsMatchLauncherMaintenancePolicy() throws {
        let data = try Data(contentsOf: macosURL.appendingPathComponent("Runtime/vm/daemon.json"))
        let config = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(config["pidfile"] as? String == "/run/docker.pid")
        #expect(config["restart"] as? Bool == false)
        #expect(config["log-driver"] as? String == ContainerRuntimeMaintenance.loggingDriver)
        #expect(config["log-opts"] as? [String: String] == ContainerRuntimeMaintenance.loggingOptions)
        let builder = try #require(config["builder"] as? [String: Any])
        let gc = try #require(builder["gc"] as? [String: Any])
        #expect(gc["enabled"] as? Bool == false)
    }
}
