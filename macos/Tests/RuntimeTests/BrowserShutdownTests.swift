import Darwin
import Foundation
import Testing
@testable import macos

struct BrowserShutdownTests {
    private func spawn(
        script: String, arguments: [String] = [],
        incoming: Pipe = Pipe(), outgoing: Pipe = Pipe()
    ) throws -> (pid: pid_t, completion: Task<Int32, Never>) {
        let ready = Pipe()
        let handles = [outgoing.fileHandleForReading, incoming.fileHandleForWriting, ready.fileHandleForWriting]
        let descriptors = handles.map { fcntl($0.fileDescriptor, F_DUPFD_CLOEXEC, 10) }
        defer { descriptors.filter { $0 >= 0 }.forEach { close($0) } }
        try #require(descriptors.allSatisfy { $0 >= 0 })
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (source, destination) in zip(descriptors, [Int32(3), 4, 1]) {
            posix_spawn_file_actions_adddup2(&actions, source, destination)
        }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let strings = (["/bin/bash", "-c", script, "browser-shutdown-test"] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/bin/bash", &actions, &attributes, $0.baseAddress!, environ)
        }
        try #require(result == 0)
        let processID = pid
        let completion = Task.detached { () -> Int32 in
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
            return status
        }
        var isReady = false
        defer { if !isReady { kill(-processID, SIGKILL) } }
        try ready.fileHandleForWriting.close()
        var descriptor = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&descriptor, 1, 5_000) > 0)
        try #require(ready.fileHandleForReading.read(upToCount: 1) == Data("R".utf8))
        try outgoing.fileHandleForReading.close()
        try incoming.fileHandleForWriting.close()
        isReady = true
        return (processID, completion)
    }

    @Test func gracefulCloseWaitsForProfileWritesWithoutSignals() async throws {
        // Unix socket addresses must fit sun_path even in deeply nested CI checkouts.
        let root = URL(fileURLWithPath: "/tmp/xe-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let incoming = Pipe()
        let outgoing = Pipe()
        let transport = CDPTransport()
        try transport.start(reader: incoming.fileHandleForReading, writer: outgoing.fileHandleForWriting,
                            socketURL: root.appendingPathComponent("cdp.sock"))
        defer { transport.stop() }
        let marker = root.appendingPathComponent("flushed")
        let browser = try spawn(script: """
            trap 'exit 23' TERM
            printf R
            IFS= read -r -d '' command <&3 || exit 24
            case "$command" in *'"method":"Browser.close"'*) ;; *) exit 25 ;; esac
            # Close may disconnect before replying. Storage must still finish
            # after the debugger connection has gone away.
            exec 4>&-
            (/bin/sleep 0.2; printf clean > "$1") &
            exit 0
            """, arguments: [marker.path], incoming: incoming, outgoing: outgoing)
        defer { kill(-browser.pid, SIGKILL) }
        var logs: [String] = []
        #expect(BrowserShutdown.stop(processGroup: browser.pid, transport: transport) { logs.append($0) })
        #expect(await browser.completion.value == 0)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "clean")
        #expect(!logs.contains { $0.contains("sending SIG") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cdp.sock").path))
    }

    @Test(arguments: [false, true])
    func stalledBrowserUsesBoundedSignalFallback(ignoresTermination: Bool) async throws {
        let browser = try spawn(script: """
            \(ignoresTermination ? "trap '' TERM" : ":")
            printf R
            exec /bin/sleep 30
            """)
        defer { kill(-browser.pid, SIGKILL) }
        let transport = CDPTransport()
        var logs: [String] = []
        #expect(BrowserShutdown.stop(processGroup: browser.pid, transport: transport,
                                     gracefulTimeout: 0.1) { logs.append($0) })
        let status = await browser.completion.value
        #expect(status & 0x7f == (ignoresTermination ? SIGKILL : SIGTERM))
        #expect(logs.contains { $0.contains("sending SIGTERM") })
        #expect(logs.contains { $0.contains("sending SIGKILL") } == ignoresTermination)
    }
}
