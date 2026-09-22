import Foundation
import Darwin
import Testing
@testable import macos

@Suite(.serialized)
@MainActor
struct WorkerdServerTests {
    @MainActor private final class LogCollector { var lines: [String] = [] }
    private let macosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func hostLifecycleWithoutVM() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-workerd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = macosRoot.appendingPathComponent(".build/workerd/workerd")
        let assets = macosRoot.appendingPathComponent(".build/compose-ui")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Run make workerd compose-ui before runtime tests")
        let config = macosRoot.appendingPathComponent(".build/workerd/resources/worker.bin")
        try #require(FileManager.default.fileExists(atPath: config.path), "Run make workerd to stage the compiled worker release before runtime tests")
        let managementPort = try freePort()
        var routingPort = try freePort()
        while routingPort == managementPort { routingPort = try freePort() }
        var tlsPort = try freePort()
        while tlsPort == managementPort || tlsPort == routingPort { tlsPort = try freePort() }
        let runtimeStatus = root.appendingPathComponent("runtime-status", isDirectory: true)
        let logs = LogCollector()
        let server = WorkerdServer(executableURL: binary, configURL: config, assetsURL: assets, stateURL: root,
                                  runtimeStatusURL: runtimeStatus,
                                  managementPort: managementPort, routingPort: routingPort,
                                  tlsPort: tlsPort, log: { logs.lines.append($0) })
        let absent = root.appendingPathComponent("missing.sock")
        do { try await server.start(composeSocketURL: absent, routerSocketURL: absent) }
        catch {
            Issue.record("workerd startup: \(error); logs: \(logs.lines.joined(separator: " | "))")
            throw error
        }
        do {
            #expect(server.isRunning)
            let second = WorkerdServer(executableURL: binary, configURL: config, assetsURL: assets,
                                       stateURL: root, runtimeStatusURL: runtimeStatus, log: { _ in })
            await #expect(throws: WorkerdError.self) { try await second.start(composeSocketURL: absent, routerSocketURL: absent) }
            await second.stop()
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: server.uiURL)
            request.setValue("127.0.0.1:8094", forHTTPHeaderField: "Host")
            let (html, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(html == (try Data(contentsOf: assets.appendingPathComponent("index.html"))))
            request.url = server.uiURL.appendingPathComponent("v1.24/ls")
            let (_, apiResponse) = try await session.data(for: request)
            #expect((apiResponse as? HTTPURLResponse)?.statusCode == 503)
            await server.stop()
            #expect(!server.isRunning)
            try await server.start(composeSocketURL: absent, routerSocketURL: absent)
            #expect(server.isRunning)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(result == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        try #require(found == 0)
        return UInt16(bigEndian: address.sin_port)
    }
}
