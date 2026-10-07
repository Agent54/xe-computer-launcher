import Foundation
import Darwin
import Synchronization
import Testing
@testable import macos

@Suite(.serialized)
@MainActor
struct WorkerdServerTests {
    @MainActor private final class LogCollector { var lines: [String] = [] }
    private let macosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func orphanCleanupOnlySelectsThisAccountsXeWorkerd() {
        let stateURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/dev.xe.computer/workerd")
        let command = "/Applications/Xe Launcher.app/Contents/Helpers/workerd serve --experimental " +
            stateURL.appendingPathComponent("ui-https/config.capnp").path +
            " --socket-addr management=127.0.0.1:8094 --socket-fd ingest=3"
        func matches(_ parentPID: pid_t = 1, _ uid: uid_t = 501, _ args: String = command,
                     _ directory: URL = stateURL) -> Bool {
            WorkerdOrphanCleanup.matchesOwnedOrphan(parentPID: parentPID, uid: uid,
                                                    commandAndArguments: args, stateURL: directory,
                                                    currentUID: 501)
        }
        #expect(matches())
        #expect(!matches(42))
        #expect(!matches(1, 502))
        #expect(!matches(1, 501, command.replacingOccurrences(of: "/Contents/Helpers/workerd", with: "/Other/workerd")))
        #expect(!matches(1, 501, command.replacingOccurrences(of: "management=127.0.0.1:8094", with: "management=127.0.0.1:8095")))
        #expect(!matches(1, 501, command, stateURL.appendingPathComponent("another-app")))
        let psOutput = """
           77     1   501 \(command)
           78    77   501 \(command)
           79     1   502 \(command)
           80     1   501 /usr/local/bin/workerd serve --experimental \(stateURL.path)/ui-https/config.capnp --socket-addr management=127.0.0.1:8094
           """
        #expect(WorkerdOrphanCleanup.candidatePIDs(in: psOutput, stateURL: stateURL, currentUID: 501) == [77])
    }

    @Test func hostLifecycleWithoutVM() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-workerd-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = macosRoot.appendingPathComponent(".build/workerd/workerd")
        let assets = macosRoot.appendingPathComponent(".build/compose-ui")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "Run make workerd compose-ui before runtime tests")
        let config = macosRoot.deletingLastPathComponent().appendingPathComponent("workerd/config.capnp")
        let managementPort = try freePort()
        var routingPort = try freePort()
        while routingPort == managementPort { routingPort = try freePort() }
        var tlsPort = try freePort()
        while tlsPort == managementPort || tlsPort == routingPort { tlsPort = try freePort() }
        let runtimeStatus = root.appendingPathComponent("runtime-status", isDirectory: true)
        let maintenanceSocket = root.appendingPathComponent("maintenance.sock")
        let cleanupRuns = Mutex(0)
        let maintenance = ContainerMaintenanceServer(socketURL: maintenanceSocket) { run in
            if run { cleanupRuns.withLock { $0 += 1 } }
            return ContainerMaintenanceServer.Reply(
                status: run ? 202 : 200,
                body: Data("{\"running\":\(run),\"completedAt\":\"2026-10-04T06:05:19Z\",\"results\":[]}".utf8)
            )
        }
        try maintenance.start()
        defer { maintenance.stop() }
        let logs = LogCollector()
        let server = WorkerdServer(executableURL: binary, configURL: config,
                                  assetsURL: assets, stateURL: root,
                                  runtimeStatusURL: runtimeStatus,
                                  maintenanceSocketURL: maintenanceSocket,
                                  dockerSocketURL: root.appendingPathComponent("missing-docker.sock"),
                                  managementPort: managementPort, routingPort: routingPort,
                                  tlsPort: tlsPort, log: { logs.lines.append($0) })
        let absent = root.appendingPathComponent("missing.sock")
        do { try await server.start(composeSocketURL: absent, routerSocketURL: absent) }
        catch {
            Issue.record("workerd startup: \(error); logs: \(logs.lines.joined(separator: " | "))")
            throw error
        }
        await server.notifyRuntimeChanged()
        let startupList = try Data(contentsOf: runtimeStatus.appendingPathComponent("startup-services.json"))
        #expect(try JSONSerialization.jsonObject(with: startupList) is [Any])
        let startupSocket = try #require((try FileManager.default.contentsOfDirectory(atPath: root.path))
            .first { $0.hasPrefix("s-") && $0.hasSuffix(".sock") })
        #expect(await UnixSocketHTTP.isReady(at: root.appendingPathComponent(startupSocket), path: "/reconcile"))
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
            try Data(#"{"phase":"healthy","message":"Ready"}"#.utf8)
                .write(to: runtimeStatus.appendingPathComponent("status.json"))
            // Initialize disk tracking before cleanup, even with Docker unavailable.
            var inventoryRequest = URLRequest(url: server.uiURL.appendingPathComponent("v1.24/disk-usage"))
            inventoryRequest.setValue("127.0.0.1:8094", forHTTPHeaderField: "Host")
            let (_, inventoryResponse) = try await session.data(for: inventoryRequest)
            #expect((inventoryResponse as? HTTPURLResponse)?.statusCode == 503)
            var cleanupRequest = URLRequest(url: server.uiURL.appendingPathComponent("v1.24/disk-usage/cleanup"))
            cleanupRequest.setValue("127.0.0.1:8094", forHTTPHeaderField: "Host")
            let (statusBody, statusResponse) = try await session.data(for: cleanupRequest)
            #expect((statusResponse as? HTTPURLResponse)?.statusCode == 200,
                    "cleanup status: \(String(decoding: statusBody, as: UTF8.self)); logs: \(logs.lines.joined(separator: " | "))")
            #expect(cleanupRuns.withLock { $0 } == 0)
            cleanupRequest.httpMethod = "POST"
            let (cleanupBody, cleanupResponse) = try await session.data(for: cleanupRequest)
            #expect((cleanupResponse as? HTTPURLResponse)?.statusCode == 202,
                    "cleanup trigger: \(String(decoding: cleanupBody, as: UTF8.self)); logs: \(logs.lines.joined(separator: " | "))")
            #expect(cleanupRuns.withLock { $0 } == 1)
            var publicHTTP = URLRequest(url: URL(string: "http://127.0.0.1:\(routingPort)/")!)
            publicHTTP.setValue("compose-ui.localhost:\(routingPort)", forHTTPHeaderField: "Host")
            let (publicHTML, publicResponse) = try await session.data(for: publicHTTP)
            #expect((publicResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(publicHTML == html)
            let httpsURL = "https://compose-ui.localhost:\(tlsPort)/"
            let socketPath = try #require((try FileManager.default.contentsOfDirectory(atPath: root.path))
                .first { $0.hasPrefix("u-") && $0.hasSuffix(".sock") })
            let direct = Process()
            direct.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            let rootCertificate = root.appendingPathComponent("ui-https/root.crt")
            direct.arguments = ["--disable", "--silent", "--show-error", "--cacert", rootCertificate.path, "--noproxy", "*",
                                "--unix-socket", root.appendingPathComponent(socketPath).path,
                                httpsURL]
            let directOutput = Pipe()
            direct.standardOutput = directOutput
            direct.standardError = directOutput
            try direct.run()
            direct.waitUntilExit()
            let directBody = directOutput.fileHandleForReading.readDataToEndOfFile()
            #expect(direct.terminationStatus == 0,
                    "direct TLS: \(String(decoding: directBody, as: UTF8.self)); logs: \(logs.lines.joined(separator: " | "))")
            if direct.terminationStatus == 0 {
                #expect(directBody.count == html.count,
                        "direct body: \(String(decoding: directBody.prefix(100), as: UTF8.self))")
            }
            let wildcard = Process()
            wildcard.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            wildcard.arguments = ["--disable", "--silent", "--show-error", "--cacert", rootCertificate.path,
                                  "--noproxy", "*", "--unix-socket", root.appendingPathComponent(socketPath).path,
                                  "--output", "/dev/null", "--write-out", "%{http_code}",
                                  "https://web_demo.app.localhost:\(tlsPort)/"]
            let wildcardOutput = Pipe()
            wildcard.standardOutput = wildcardOutput
            wildcard.standardError = wildcardOutput
            try wildcard.run()
            wildcard.waitUntilExit()
            let wildcardResult = String(decoding: wildcardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let cert = Process()
            cert.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            cert.arguments = ["x509", "-noout", "-text", "-in",
                              root.appendingPathComponent("ui-https/ui.crt").path]
            let certOutput = Pipe()
            cert.standardOutput = certOutput
            cert.standardError = certOutput
            try cert.run()
            cert.waitUntilExit()
            let certSAN = String(decoding: certOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \.isNewline).filter { $0.contains("DNS:") }.joined(separator: " | ")
            #expect(certSAN.contains("DNS:compose-ui.localhost"))
            #expect(certSAN.contains("DNS:*.app.localhost"))
            #expect(!certSAN.contains("DNS:*.localhost"))
            #expect(wildcard.terminationStatus == 0, "wildcard TLS: \(wildcardResult); SAN: \(certSAN)")
            #expect(wildcardResult == "503")
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["--disable", "--silent", "--show-error", "--cacert", rootCertificate.path, "--noproxy", "*",
                              "--resolve", "compose-ui.localhost:\(tlsPort):127.0.0.1", httpsURL]
            let curlOutput = Pipe()
            curl.standardOutput = curlOutput
            curl.standardError = curlOutput
            try curl.run()
            curl.waitUntilExit()
            let tlsBody = curlOutput.fileHandleForReading.readDataToEndOfFile()
            #expect(curl.terminationStatus == 0, "curl: \(String(decoding: tlsBody, as: UTF8.self)); logs: \(logs.lines.joined(separator: " | "))")
            if curl.terminationStatus == 0 { #expect(tlsBody == html) }
            let savedPorts = try Data(contentsOf: runtimeStatus.appendingPathComponent("app-ports.json"))
            #expect(String(decoding: savedPorts, as: UTF8.self).contains("\"http\":\(routingPort)"))
            #expect(String(decoding: savedPorts, as: UTF8.self).contains("\"publicHttpReady\":true"))
            request.url = server.uiURL.appendingPathComponent("v1.24/ls")
            let (_, apiResponse) = try await session.data(for: request)
            #expect((apiResponse as? HTTPURLResponse)?.statusCode == 503)
            await server.stop()
            #expect(!server.isRunning)
            try await server.start(composeSocketURL: absent, routerSocketURL: absent)
            #expect(server.isRunning)
            let publicPID = try #require(server.processIdentifier)
            // Simulate a crash. SIGTERM starts workerd's graceful connection
            // drain, whose duration is not part of this restart check.
            try #require(kill(publicPID, SIGKILL) == 0)
            let deadline = ContinuousClock.now + .seconds(8)
            while server.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(!server.isRunning)
            try await server.start(composeSocketURL: absent, routerSocketURL: absent)
            #expect(server.isRunning)
            let restarted = Process()
            restarted.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            restarted.arguments = ["--disable", "--silent", "--show-error", "--cacert", rootCertificate.path, "--noproxy", "*",
                                   "--resolve", "compose-ui.localhost:\(tlsPort):127.0.0.1", httpsURL]
            let restartedOutput = Pipe()
            restarted.standardOutput = restartedOutput
            restarted.standardError = restartedOutput
            try restarted.run()
            restarted.waitUntilExit()
            let restartedBody = restartedOutput.fileHandleForReading.readDataToEndOfFile()
            #expect(restarted.terminationStatus == 0)
            if restarted.terminationStatus == 0 { #expect(restartedBody == html) }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func managementRemainsAvailableWhilePortHelperNeedsApproval() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-workerd-pending-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = macosRoot.appendingPathComponent(".build/workerd/workerd")
        let config = macosRoot.deletingLastPathComponent().appendingPathComponent("workerd/config.capnp")
        let assets = macosRoot.appendingPathComponent(".build/compose-ui")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        try #require(FileManager.default.fileExists(atPath: config.path))
        let logs = LogCollector()
        let server = WorkerdServer(executableURL: binary, configURL: config,
                                   assetsURL: assets,
                                   stateURL: root, runtimeStatusURL: root.appendingPathComponent("status"),
                                   managementPort: try freePort(), routingPort: 80, tlsPort: 443,
                                   acquirePrivilegedSockets: { throw PrivilegedPortError.approvalRequired },
                                   log: { logs.lines.append($0) })
        let absent = root.appendingPathComponent("missing.sock")
        try await server.start(composeSocketURL: absent, routerSocketURL: absent)
        do {
            #expect(server.isRunning)
            #expect(logs.lines.contains { $0.contains("port helper") })
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inactive-http.sock").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inactive-https.sock").path))
            let savedPorts = try Data(contentsOf: root.appendingPathComponent("status/app-ports.json"))
            #expect(String(decoding: savedPorts, as: UTF8.self).contains("\"publicHttpReady\":false"))
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: server.uiURL)
            request.setValue("127.0.0.1:8094", forHTTPHeaderField: "Host")
            let (html, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(!html.isEmpty)
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
