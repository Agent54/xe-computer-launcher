import Foundation
import Darwin

enum UnixSocketHTTP {
    /// Probe HTTP directly over AF_UNIX without spawning a helper. All I/O is
    /// nonblocking and shares one deadline, off the main actor.
    static func isReady(at socketURL: URL, path: String = "/_ping", timeout: Duration = .seconds(1)) async -> Bool {
        guard path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n") else { return false }
        return await Task.detached {
            probe(socketURL: socketURL, path: path, deadline: .now + timeout)
        }.value
    }

    private static func probe(socketURL: URL, path: String, deadline: ContinuousClock.Instant) -> Bool {
        var address = sockaddr_un()
        let bytes = Array(socketURL.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  wait(descriptor, for: POLLOUT, until: deadline) else { return false }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
        }

        let request = Array("GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < request.count {
            guard wait(descriptor, for: POLLOUT, until: deadline) else { return false }
            let count = request.withUnsafeBytes {
                send(descriptor, $0.baseAddress!.advanced(by: sent), request.count - sent, 0)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return false }
            sent += count
        }

        var response = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while response.count < 4096 {
            guard wait(descriptor, for: POLLIN, until: deadline) else { return false }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return false }
            response.append(contentsOf: buffer.prefix(count))
            let text = String(decoding: response, as: UTF8.self)
            if let end = text.range(of: "\r\n") {
                let fields = text[..<end.lowerBound].split(separator: " ")
                guard fields.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(fields[0]),
                      let status = Int(fields[1]) else { return false }
                return (200..<300).contains(status)
            }
        }
        return false
    }

    private static func wait(_ descriptor: Int32, for events: Int32, until deadline: ContinuousClock.Instant) -> Bool {
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
            var descriptor = pollfd(fd: descriptor, events: Int16(events), revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(milliseconds, 1000))))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            return result > 0 && Int32(descriptor.revents) & (events | POLLHUP | POLLERR) != 0
        }
        return false
    }
}
