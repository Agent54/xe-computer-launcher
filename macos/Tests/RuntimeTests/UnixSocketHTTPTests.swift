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
        let result = try await probeResponse(chunks: [], stall: .milliseconds(500), timeout: .milliseconds(100))
        #expect(!result.ready)
        #expect(result.elapsed < .milliseconds(400))
    }

    @Test func rejectsOversizedSocketPath() async {
        #expect(await !UnixSocketHTTP.isReady(at: URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 150))))
    }

    @Test func balloonQueryReadsFragmentedReply() async throws {
        let result = try await probeResponse(chunks: ["OK target=1", "024 actual=768\n"], balloon: true)
        #expect(result.line == "OK target=1024 actual=768")
        #expect(result.request == "BALLOON\n")
    }

    @Test func stalledBalloonQueryHonorsDeadline() async throws {
        let result = try await probeResponse(chunks: [], stall: .milliseconds(500), timeout: .milliseconds(100), balloon: true)
        #expect(result.line == nil)
        #expect(result.elapsed < .milliseconds(400))
    }

    /// A native Unix socket fixture; no Docker, VM, or subprocess required.
    private func probeResponse(
        chunks: [String], stall: Duration = .zero, timeout: Duration = .seconds(1), balloon: Bool = false
    ) async throws -> (ready: Bool, line: String?, request: String?, elapsed: Duration) {
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

        let peer = Task.detached {
            var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 2000) > 0 else { return nil as String? }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return nil as String? }
            defer { close(connection) }
            var enabled: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
            var incoming = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            guard poll(&incoming, 1, 1000) > 0 else { return nil as String? }
            var request = [UInt8](repeating: 0, count: 1024)
            let count = recv(connection, &request, request.count, 0)
            let received = count > 0 ? String(decoding: request.prefix(count), as: UTF8.self) : nil
            try? await Task.sleep(for: stall)
            for chunk in chunks {
                let bytes = Array(chunk.utf8)
                _ = bytes.withUnsafeBytes { send(connection, $0.baseAddress, bytes.count, 0) }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return received
        }
        let started = ContinuousClock.now
        let line = balloon ? await UnixSocketHTTP.balloonStatus(at: URL(fileURLWithPath: path), timeout: timeout) : nil
        let ready = balloon ? false : await UnixSocketHTTP.isReady(at: URL(fileURLWithPath: path), timeout: timeout)
        let elapsed = started.duration(to: .now)
        let request = await peer.value
        return (ready, line, request, elapsed)
    }
}
