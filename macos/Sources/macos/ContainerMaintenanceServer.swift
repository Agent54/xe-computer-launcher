import Darwin
import Foundation

/// Private host API used by workerd. Automatic and manual cleanup share the supervisor.
@MainActor
final class ContainerMaintenanceServer {
    static var socketURL: URL { SmolVMPaths.socketsURL.appendingPathComponent("maintenance.sock") }
    struct Reply: Sendable {
        let status: Int
        let body: Data
    }
    typealias Handler = @Sendable (Bool) async -> Reply

    private let socketURL: URL
    private let handler: Handler
    private var source: DispatchSourceRead?

    init(socketURL: URL = ContainerMaintenanceServer.socketURL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    func start() throws {
        guard source == nil else { return }
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var address = sockaddr_un()
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        // The supervisor owns this socket for the launcher's lifetime.
        var existing = stat()
        if lstat(socketURL.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == getuid() else {
                throw CocoaError(.fileWriteFileExists)
            }
            unlink(socketURL.path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketURL.path, 0o600) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              listen(descriptor, 8) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            unlink(socketURL.path)
            throw error
        }
        let handler = self.handler
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { @Sendable in
            // Bound each accept batch so a busy client cannot monopolize this queue.
            for _ in 0..<8 {
                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { break }
                Task.detached(priority: .utility) {
                    defer { close(connection) }
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else { return }
                    var enabled: Int32 = 1
                    guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                          fcntl(connection, F_SETFL, O_NONBLOCK) == 0,
                          setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                                     socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { return }
                    guard let request = Self.readRequest(connection) else { return }
                    let reply: Reply
                    switch request {
                    case "GET /status HTTP/1.1", "GET /status HTTP/1.0": reply = await handler(false)
                    case "POST /cleanup HTTP/1.1", "POST /cleanup HTTP/1.0": reply = await handler(true)
                    default: reply = Reply(status: 404, body: Data("{\"message\":\"Not found\"}".utf8))
                    }
                    Self.writeReply(reply, to: connection)
                }
            }
        }
        source.setCancelHandler { @Sendable in close(descriptor) }
        self.source = source
        source.resume()
    }

    func stop() {
        if source != nil { unlink(socketURL.path) }
        source?.cancel()
        source = nil
    }

    nonisolated private static func readRequest(_ descriptor: Int32) -> String? {
        let deadline = ContinuousClock.now + .seconds(5)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < 8192, ContinuousClock.now < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 100) >= 0 else { return nil }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")
                // Only these fixed, body-free operations are supported.
                guard headers.dropFirst().allSatisfy({
                    let lower = $0.lowercased()
                    return !lower.hasPrefix("transfer-encoding:") &&
                        (!lower.hasPrefix("content-length:") || lower.dropFirst(15).trimmingCharacters(in: .whitespaces) == "0")
                }) else { return nil }
                return headers.first
            }
        }
        return nil
    }

    nonisolated private static func writeReply(_ reply: Reply, to descriptor: Int32) {
        var data = Data("HTTP/1.1 \(reply.status) Result\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(reply.body.count)\r\n\r\n".utf8)
        data.append(reply.body)
        let deadline = ContinuousClock.now + .seconds(5)
        var sent = 0
        while sent < data.count, ContinuousClock.now < deadline {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollDescriptor, 1, 100) >= 0 else { return }
            let count = data.withUnsafeBytes {
                send(descriptor, $0.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { return }
            sent += count
        }
    }
}
