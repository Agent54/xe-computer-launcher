import Darwin
import Foundation
import Testing
@testable import macos

struct UnixSocketHTTPTests {
    @Test func acceptsFragmentedStatusLine() async throws {
        let result = try await probeResponse(chunks: ["HTTP/1.1 2", "00 OK\r", "\nContent-Length: 0\r\n\r\n"])
        #expect(result.ready)
    }

    @Test(arguments: ["HTTP/1.1 503 Unavailable\r\n\r\n", "garbage 200 OK\r\n", "HTTP/1.1 200", ""])
    func rejectsErrorsAndIncompleteResponses(response: String) async throws {
        let result = try await probeResponse(chunks: [response])
        #expect(!result.ready)
    }

    @Test func stalledPeerHonorsDeadline() async throws {
        let result = try await probeResponse(chunks: [], waitForClientClose: true, timeout: .milliseconds(100))
        #expect(!result.ready)
        // The client must time out while the peer is still holding the socket
        // open. Task scheduling and continuation delays are not socket I/O.
        #expect(result.peerSawClientClose)
    }

    @Test func rejectsOversizedSocketPath() async {
        #expect(await !UnixSocketHTTP.isReady(at: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 150))))
    }

    /// A native Unix socket fixture; no Docker, VM, or subprocess required.
    private func probeResponse(
        chunks: [String], waitForClientClose: Bool = false, timeout: Duration = .seconds(1)
    ) async throws -> (ready: Bool, peerSawClientClose: Bool) {
        let path = "/tmp/xe-probe-\(UUID().uuidString.prefix(8)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer {
            close(listener)
            unlink(path)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)

        async let peerSawClientClose: Bool = withCheckedContinuation { continuation in
            // Blocking fixture I/O must not occupy Swift's cooperative workers,
            // where it could delay the very probe being tested.
            DispatchQueue.global().async {
                var sawClientClose = false
                defer { continuation.resume(returning: sawClientClose) }
                var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&pending, 1, 2000) > 0 else { return }
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                defer { close(connection) }
                var enabled: Int32 = 1
                _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
                var incoming = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                guard poll(&incoming, 1, 1000) > 0 else { return }
                var request = [UInt8](repeating: 0, count: 1024)
                guard recv(connection, &request, request.count, 0) > 0 else { return }
                if waitForClientClose {
                    // A generous watchdog bounds a broken probe. If it fires,
                    // the fixture closes the peer and the assertion must fail.
                    var disconnect = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
                    guard poll(&disconnect, 1, 5000) > 0 else { return }
                    var byte: UInt8 = 0
                    sawClientClose = recv(connection, &byte, 1, 0) == 0
                    return
                }
                for chunk in chunks {
                    let bytes = Array(chunk.utf8)
                    _ = bytes.withUnsafeBytes { send(connection, $0.baseAddress, bytes.count, 0) }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        let ready = await UnixSocketHTTP.isReady(at: URL(fileURLWithPath: path), timeout: timeout)
        return (ready, await peerSawClientClose)
    }
}
