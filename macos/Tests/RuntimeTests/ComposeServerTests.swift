import Foundation
import Testing
@testable import macos

@Suite(.serialized)
@MainActor
struct ComposeServerTests {
    private func temporaryRoot() throws -> URL {
        // Keep Unix socket paths short even on macOS's long TMPDIR paths.
        let url = URL(fileURLWithPath: "/tmp/xe-compose-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func rejectsMissingHelper() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ComposeServer(executableURL: root.appendingPathComponent("missing"), stacksURL: root, log: { _ in })
        await #expect(throws: ComposeServerError.self) {
            try await server.start(dockerSocketURL: root.appendingPathComponent("docker.sock"))
        }
        #expect(!server.isRunning)
    }

    @Test func reportsEarlyExit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexit 42\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let server = ComposeServer(executableURL: helper, stacksURL: root, log: { _ in })
        do {
            try await server.start(dockerSocketURL: root.appendingPathComponent("docker.sock"))
            Issue.record("An exited process must not be reported as ready")
        } catch ComposeServerError.exited(let code) {
            #expect(code == 42)
        }
        #expect(!server.isRunning)
    }

    @Test func cancellationStopsStartingProcess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        try Data("#!/bin/sh\nexec /bin/sleep 60\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let server = ComposeServer(executableURL: helper, stacksURL: root, log: { _ in })
        let task = Task { try await server.start(dockerSocketURL: root.appendingPathComponent("docker.sock")) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(server.isRunning)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!server.isRunning)
    }

    @Test func regularFileIsNotAReadyDockerSocket() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("docker.sock")
        try Data().write(to: socket)
        #expect(await !UnixSocketHTTP.isReady(at: socket))
    }

    @Test func bundledForkLifecycle() async throws {
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/compose-server/docker-compose")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path), "Run make compose-server before swift test")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ComposeServer(executableURL: helper, stacksURL: root, log: { _ in })
        let dockerSocket = root.appendingPathComponent("docker.sock")
        let socket = try await server.start(dockerSocketURL: dockerSocket)
        do {
            #expect(await UnixSocketHTTP.isReady(at: socket))
            #expect(try await server.start(dockerSocketURL: dockerSocket) == socket)
            // A second launcher must not unlink the first launcher's live socket.
            let second = ComposeServer(executableURL: helper, stacksURL: root, log: { _ in })
            await #expect(throws: ComposeServerError.self) { try await second.start(dockerSocketURL: dockerSocket) }
            #expect(!second.isRunning)
            #expect(await UnixSocketHTTP.isReady(at: socket))
            await server.stop()
            #expect(!server.isRunning)
            #expect(await !UnixSocketHTTP.isReady(at: socket))
            // The same root can be used after quit/update cleanup.
            try await server.start(dockerSocketURL: dockerSocket)
            #expect(await UnixSocketHTTP.isReady(at: socket))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPOSE_TEST_DOCKER_SOCKET"] != nil))
    func forwardsRequestsToSmol() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["COMPOSE_TEST_DOCKER_SOCKET"])
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/compose-server/docker-compose")
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = ComposeServer(executableURL: helper, stacksURL: root, log: { _ in })
        let socket = try await server.start(dockerSocketURL: URL(fileURLWithPath: path))
        do {
            let responseURL = root.appendingPathComponent("response.json")
            let request = Process()
            request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            request.arguments = [
                "--disable", "--silent", "--show-error", "--fail", "--max-time", "10", "--noproxy", "*",
                "--unix-socket", socket.path, "--output", responseURL.path, "http://localhost/ls?all=true",
            ]
            try request.run()
            request.waitUntilExit()
            try #require(request.terminationStatus == 0)
            let projects = try JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
            #expect(projects is [[String: Any]])
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
