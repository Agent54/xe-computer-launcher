import Darwin
import Foundation
import Testing
@testable import macos

struct CDPTransportTests {
    private func directory() throws -> URL {
        // Unix socket addresses must stay short even in deeply nested CI checkouts.
        let root = URL(fileURLWithPath: "/tmp/xe-cdp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    private func connectSocket(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(descriptor); throw POSIXError(.ECONNREFUSED) }
        return descriptor
    }

    private func readMessages(_ descriptor: Int32, count: Int) throws -> [[String: Any]] {
        var buffer = Data()
        var results: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(5)
        while results.count < count, Date() < deadline {
            var pfd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let length = read(descriptor, &bytes, bytes.count)
            guard length > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(length))
            while let zero = buffer.firstIndex(of: 0) {
                let message = try JSONSerialization.jsonObject(with: Data(buffer[..<zero])) as! [String: Any]
                results.append(message)
                buffer.removeSubrange(...zero)
            }
        }
        try #require(results.count == count)
        return results
    }

    @Test func sharesPipeWithoutStealingRepliesAndKeepsEvents() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let toBrowser = Pipe()
        let fromBrowser = Pipe()
        let transport = CDPTransport()
        try transport.start(reader: fromBrowser.fileHandleForReading,
                            writer: toBrowser.fileHandleForWriting,
                            socketURL: root.appendingPathComponent("debug.sock"))
        defer { transport.stop() }
        let first = try connectSocket(root.appendingPathComponent("debug.sock").path)
        let second = try connectSocket(root.appendingPathComponent("debug.sock").path)
        defer { close(first); close(second) }
        let command = Data("{\"id\":1,\"method\":\"Target.getTargets\"}\0".utf8)
        _ = command.withUnsafeBytes { write(first, $0.baseAddress, command.count) }
        _ = command.withUnsafeBytes { write(second, $0.baseAddress, command.count) }
        let local = Task.detached {
            transport.command(method: "Browser.getVersion", params: [:], sessionID: nil, timeout: 5)?["result"] != nil
        }
        let commands = try readMessages(toBrowser.fileHandleForReading.fileDescriptor, count: 3)
        #expect(Set(commands.compactMap { $0["id"] as? Int }).count == 3)
        var responses = Data()
        for command in commands.reversed() {
            responses.append(try JSONSerialization.data(withJSONObject: ["id": command["id"]!, "result": ["ok": true]]))
            responses.append(0)
        }
        responses.append(Data("{\"method\":\"Target.targetCreated\",\"params\":{\"title\":\"한글\"}}\0".utf8))
        let split = responses.count - 4
        try fromBrowser.fileHandleForWriting.write(contentsOf: responses.prefix(split))
        try fromBrowser.fileHandleForWriting.write(contentsOf: responses.suffix(responses.count - split))
        for descriptor in [first, second] {
            let replies = try readMessages(descriptor, count: 2)
            #expect(replies.first?["id"] as? Int == 1)
            #expect(replies.last?["method"] as? String == "Target.targetCreated")
        }
        #expect(await local.value)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("debug.sock").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func stopWakesCommandsAndAllowsRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CDPTransport()
        for _ in 0..<2 {
            let toBrowser = Pipe()
            let fromBrowser = Pipe()
            try transport.start(reader: fromBrowser.fileHandleForReading, writer: toBrowser.fileHandleForWriting,
                                socketURL: root.appendingPathComponent("debug.sock"))
            let local = Task.detached {
                transport.command(method: "Browser.getVersion", params: [:], sessionID: nil, timeout: 5)?["error"] != nil
            }
            _ = try readMessages(toBrowser.fileHandleForReading.fileDescriptor, count: 1)
            transport.stop()
            #expect(await local.value)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("debug.sock").path))
        }
    }

    @Test func neverReplacesARegularFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("debug.sock")
        try Data("keep".utf8).write(to: socket)
        let transport = CDPTransport()
        let incoming = Pipe()
        let outgoing = Pipe()
        #expect(throws: (any Error).self) {
            try transport.start(reader: incoming.fileHandleForReading, writer: outgoing.fileHandleForWriting, socketURL: socket)
        }
        #expect(try String(contentsOf: socket, encoding: .utf8) == "keep")
    }

    @Test func largeRepliesWaitForTheClientToRead() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoing = Pipe()
        let incoming = Pipe()
        let transport = CDPTransport()
        try transport.start(reader: incoming.fileHandleForReading, writer: outgoing.fileHandleForWriting,
                            socketURL: root.appendingPathComponent("debug.sock"))
        defer { transport.stop() }
        let client = try connectSocket(root.appendingPathComponent("debug.sock").path)
        defer { close(client) }
        let command = Data("{\"id\":1,\"method\":\"Page.captureScreenshot\"}\0".utf8)
        _ = command.withUnsafeBytes { write(client, $0.baseAddress, command.count) }
        let forwarded = try readMessages(outgoing.fileHandleForReading.fileDescriptor, count: 1)[0]
        var reply = try JSONSerialization.data(withJSONObject: ["id": forwarded["id"]!,
            "result": ["data": String(repeating: "x", count: 2 * 1024 * 1024)]])
        reply.append(0)
        let bytes = reply
        let writing = Task.detached { try incoming.fileHandleForWriting.write(contentsOf: bytes) }
        try await Task.sleep(for: .milliseconds(100))
        let response = try readMessages(client, count: 1)[0]
        #expect((response["result"] as? [String: Any])?["data"] as? String == String(repeating: "x", count: 2 * 1024 * 1024))
        try await writing.value
    }

    @Test func disconnectDuringAttachCleansUpTheBrowserSession() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoing = Pipe()
        let incoming = Pipe()
        let transport = CDPTransport()
        try transport.start(reader: incoming.fileHandleForReading, writer: outgoing.fileHandleForWriting,
                            socketURL: root.appendingPathComponent("debug.sock"))
        defer { transport.stop() }
        let client = try connectSocket(root.appendingPathComponent("debug.sock").path)
        let command = Data("{\"id\":1,\"method\":\"Target.attachToBrowserTarget\"}\0".utf8)
        _ = command.withUnsafeBytes { write(client, $0.baseAddress, command.count) }
        let forwarded = try readMessages(outgoing.fileHandleForReading.fileDescriptor, count: 1)[0]
        close(client)
        var reply = try JSONSerialization.data(withJSONObject: ["id": forwarded["id"]!, "result": ["sessionId": "orphan"]])
        reply.append(0)
        try incoming.fileHandleForWriting.write(contentsOf: reply)
        let detach = try readMessages(outgoing.fileHandleForReading.fileDescriptor, count: 1)[0]
        #expect(detach["method"] as? String == "Target.detachFromTarget")
        #expect((detach["params"] as? [String: Any])?["sessionId"] as? String == "orphan")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["XE_TEST_BROWSER"] != nil))
    func realBrowserPipeAndIndependentSessions() throws {
        let executable = try #require(ProcessInfo.processInfo.environment["XE_TEST_BROWSER"])
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = Pipe()
        let outgoing = Pipe()
        let commandFD = fcntl(outgoing.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 10)
        let responseFD = fcntl(incoming.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 10)
        try #require(commandFD >= 0 && responseFD >= 0)
        defer { close(commandFD); close(responseFD) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, commandFD, 3)
        posix_spawn_file_actions_adddup2(&actions, responseFD, 4)
        posix_spawn_file_actions_addclose(&actions, commandFD)
        posix_spawn_file_actions_addclose(&actions, responseFD)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let arguments = [executable, "--user-data-dir=\(root.appendingPathComponent("profile").path)",
                         "--headless=new", "--remote-debugging-pipe", "--no-first-run",
                         "--no-default-browser-check", "--disable-background-networking", "about:blank"]
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        let environmentStrings: [String] = ["HOME=\(NSHomeDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let environment = environmentStrings.map { strdup($0) }
        defer { environment.forEach { free($0) } }
        var envp = environment + [nil]
        var argv = strings + [nil]
        var pid: pid_t = 0
        let status = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, executable, &actions, nil, $0.baseAddress!, &envp)
        }
        try #require(status == 0)
        defer {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(3)
            while waitpid(pid, nil, WNOHANG) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL); waitpid(pid, nil, 0) }
        }
        outgoing.fileHandleForReading.closeFile()
        incoming.fileHandleForWriting.closeFile()
        let transport = CDPTransport()
        try transport.start(reader: incoming.fileHandleForReading, writer: outgoing.fileHandleForWriting,
                            socketURL: root.appendingPathComponent("debug.sock"))
        defer { transport.stop() }
        func command(_ method: String, _ params: [String: Any] = [:], session: String? = nil) throws -> [String: Any] {
            let reply = try #require(transport.command(method: method, params: params, sessionID: session, timeout: 10))
            #expect(reply["error"] == nil, "\(method): \(reply)")
            return try #require(reply["result"] as? [String: Any])
        }
        let version = try command("Browser.getVersion")
        #expect(version["revision"] is String)
        let first = try #require(command("Target.attachToBrowserTarget")["sessionId"] as? String)
        let second = try #require(command("Target.attachToBrowserTarget")["sessionId"] as? String)
        #expect(first != second)
        let targets = try #require(command("Target.getTargets", session: first)["targetInfos"] as? [[String: Any]])
        let target = try #require(targets.first { $0["type"] as? String == "page" }?["targetId"] as? String)
        let attached = try command("Target.attachToTarget", ["targetId": target, "flatten": true], session: first)
        let page = try #require(attached["sessionId"] as? String)
        let evaluated = try command("Runtime.evaluate", ["expression": "1+1", "returnByValue": true], session: page)
        #expect((evaluated["result"] as? [String: Any])?["value"] as? Int == 2)
        _ = try command("Target.getTargets", session: second)
        _ = try command("Target.detachFromTarget", ["sessionId": first])
        _ = try command("Target.detachFromTarget", ["sessionId": second])
        _ = try command("Browser.getVersion")
    }
}
