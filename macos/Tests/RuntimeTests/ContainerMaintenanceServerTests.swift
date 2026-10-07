import Darwin
import Foundation
import Synchronization
import Testing
@testable import macos

@MainActor
struct ContainerMaintenanceServerTests {
    private var socketURL: URL {
        // Unix socket paths must stay short regardless of the CI checkout path or TMPDIR.
        URL(fileURLWithPath: "/tmp/xe-maint-\(UUID().uuidString.prefix(8)).sock")
    }

    private func request(_ method: String, _ path: String, socket: URL) async throws -> String {
        let result = try await Task.detached {
            try ProcessCapture.standardOutput(executableURL: URL(fileURLWithPath: "/usr/bin/curl"), arguments: [
                "--disable", "--silent", "--show-error", "--noproxy", "*", "--max-time", "5",
                "--unix-socket", socket.path, "--request", method,
                "--write-out", "\n%{http_code}", "http://maintenance\(path)",
            ])
        }.value
        try #require(result.exitCode == 0)
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    @Test func onlyExplicitPostStartsCleanupAndSocketIsPrivate() async throws {
        let socket = socketURL
        let runs = Mutex(0)
        let server = ContainerMaintenanceServer(socketURL: socket) { run in
            if run { runs.withLock { $0 += 1 } }
            return ContainerMaintenanceServer.Reply(status: run ? 202 : 200, body: Data("{}".utf8))
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try await request("GET", "/status", socket: socket) == "{}\n200")
        #expect(runs.withLock { $0 } == 0)
        #expect(try await request("GET", "/cleanup", socket: socket).hasSuffix("404"))
        #expect(runs.withLock { $0 } == 0)
        #expect(try await request("POST", "/cleanup", socket: socket) == "{}\n202")
        #expect(runs.withLock { $0 } == 1)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test func neverUnlinksAnUnexpectedFile() throws {
        let socket = socketURL
        let data = Data("keep".utf8)
        try data.write(to: socket)
        defer { try? FileManager.default.removeItem(at: socket) }
        let server = ContainerMaintenanceServer(socketURL: socket) { _ in
            ContainerMaintenanceServer.Reply(status: 200, body: Data())
        }
        #expect(throws: CocoaError.self) { try server.start() }
        #expect(try Data(contentsOf: socket) == data)
    }
}
