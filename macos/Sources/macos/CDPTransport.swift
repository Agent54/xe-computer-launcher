import Darwin
import Foundation

/// Shares Chromium's null-delimited pipe with the launcher and private workerd clients.
/// HTTP routes, WebSockets and payload policy belong to workerd.
final class CDPTransport: @unchecked Sendable {
    private struct Pending {
        let originalID: Int
        let clientID: UUID?
        let method: String
        let reply: @Sendable (Data) -> Void
    }

    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var nextID = 0
    private var pending: [Int: Pending] = [:]
    private var clients: [UUID: Client] = [:]
    private var buffer = Data()
    private var reader: FileHandle?
    private var writer: FileHandle?
    private var listener: DispatchSourceRead?
    private var socketURL: URL?
    private var generation = UUID()
    private static let maximumMessage = 32 * 1024 * 1024

    func start(reader: FileHandle, writer: FileHandle, socketURL: URL) throws {
        stop()
        var address = sockaddr_un()
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
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
              listen(descriptor, 16) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            if bound == 0 { unlink(socketURL.path) }
            throw error
        }
        guard fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            close(descriptor)
            unlink(socketURL.path)
            throw POSIXError(.EIO)
        }
        condition.lock()
        self.reader = reader
        self.writer = writer
        self.socketURL = socketURL
        let generation = UUID()
        self.generation = generation
        condition.unlock()
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, generation: generation)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            for _ in 0..<16 {
                let connection = Darwin.accept(descriptor, nil, nil)
                guard connection >= 0 else { break }
                if let self { self.accept(connection, generation: generation) } else { close(connection) }
            }
        }
        source.setCancelHandler { close(descriptor) }
        condition.lock()
        listener = source
        condition.unlock()
        source.resume()
    }

    func stop(generation expectedGeneration: UUID? = nil) {
        condition.lock()
        if let expectedGeneration, generation != expectedGeneration { condition.unlock(); return }
        let reader = self.reader
        let writer = self.writer
        self.reader = nil
        self.writer = nil
        let listener = self.listener
        self.listener = nil
        let socketURL = self.socketURL
        self.socketURL = nil
        generation = UUID()
        let clients = Array(self.clients.values)
        self.clients.removeAll()
        let pending = Array(self.pending.values)
        self.pending.removeAll()
        buffer.removeAll()
        condition.unlock()
        reader?.readabilityHandler = nil
        listener?.cancel()
        if let socketURL { unlink(socketURL.path) }
        clients.forEach { $0.stop() }
        for request in pending {
            let data = try! JSONSerialization.data(withJSONObject: [
                "id": request.originalID, "error": ["code": -32000, "message": "Browser disconnected"]
            ])
            request.reply(data)
        }
        try? reader?.close()
        writeLock.lock()
        try? writer?.close()
        writeLock.unlock()
    }

    func command(method: String, params: [String: Any], sessionID: String?, timeout: TimeInterval) -> [String: Any]? {
        let result = ReplyBox()
        var message: [String: Any] = ["id": 0, "method": method, "params": params]
        if let sessionID { message["sessionId"] = sessionID }
        guard let id = send(message, reply: { result.set($0) }) else { return nil }
        let data = result.wait(timeout: timeout)
        condition.lock()
        pending.removeValue(forKey: id)
        condition.unlock()
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    @discardableResult
    private func send(_ message: [String: Any], clientID: UUID? = nil,
                      reply: @escaping @Sendable (Data) -> Void) -> Int? {
        guard let originalID = message["id"] as? Int, let method = message["method"] as? String else { return nil }
        condition.lock()
        guard let writer, pending.count < 1024 else { condition.unlock(); return nil }
        let generation = self.generation
        nextID += 1
        let id = nextID
        pending[id] = Pending(originalID: originalID, clientID: clientID, method: method, reply: reply)
        condition.unlock()
        var forwarded = message
        forwarded["id"] = id
        guard var data = try? JSONSerialization.data(withJSONObject: forwarded), data.count <= Self.maximumMessage else {
            condition.lock()
            pending.removeValue(forKey: id)
            condition.unlock()
            return nil
        }
        data.append(0)
        writeLock.lock()
        condition.lock()
        let connected = self.writer === writer && self.generation == generation
        condition.unlock()
        guard connected else { writeLock.unlock(); return nil }
        let deadline = Date().addingTimeInterval(5)
        var sent = 0
        while sent < data.count, Date() < deadline {
            var pfd = pollfd(fd: writer.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 100) < 0 { break }
            let count = data.withUnsafeBytes {
                write(writer.fileDescriptor, $0.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if count <= 0 { break }
            sent += count
        }
        writeLock.unlock()
        if sent != data.count { stop(generation: generation); return nil }
        return id
    }

    private func receive(_ data: Data, generation: UUID) {
        condition.lock()
        guard self.generation == generation else { condition.unlock(); return }
        if data.isEmpty { condition.unlock(); stop(generation: generation); return }
        buffer.append(data)
        var messages: [Data] = []
        while let delimiter = buffer.firstIndex(of: 0) {
            messages.append(Data(buffer[..<delimiter]))
            buffer.removeSubrange(...delimiter)
        }
        let oversized = buffer.count > Self.maximumMessage || messages.contains { $0.count > Self.maximumMessage }
        condition.unlock()
        if oversized { stop(generation: generation); return }
        for data in messages {
            guard var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            condition.lock()
            guard self.generation == generation else { condition.unlock(); return }
            if let id = message["id"] as? Int {
                let request = pending.removeValue(forKey: id)
                var orphanedSession: String?
                if let request, request.method == "Target.attachToBrowserTarget",
                   let clientID = request.clientID, let result = message["result"] as? [String: Any],
                   let sessionID = result["sessionId"] as? String {
                    if let client = clients[clientID] { client.addSession(sessionID) }
                    else { orphanedSession = sessionID }
                }
                condition.unlock()
                if let orphanedSession {
                    send(["id": 0, "method": "Target.detachFromTarget", "params": ["sessionId": orphanedSession]]) { _ in }
                }
                if let request {
                    message["id"] = request.originalID
                    if let response = try? JSONSerialization.data(withJSONObject: message) { request.reply(response) }
                }
            } else {
                let clients = Array(clients.values)
                condition.unlock()
                clients.forEach { $0.send(data) }
            }
        }
    }

    private func accept(_ descriptor: Int32, generation: UUID) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        var enabled: Int32 = 1
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid(),
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, 0) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                         socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else { close(descriptor); return }
        let client = Client(descriptor: descriptor)
        let id = UUID()
        condition.lock()
        guard reader != nil, self.generation == generation, clients.count < 16 else {
            condition.unlock(); close(descriptor); return
        }
        clients[id] = client
        condition.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                client.finish()
                self?.disconnect(id, client: client)
            }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(descriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                buffer.append(contentsOf: bytes.prefix(count))
                while let delimiter = buffer.firstIndex(of: 0) {
                    let data = Data(buffer[..<delimiter])
                    buffer.removeSubrange(...delimiter)
                    guard data.count <= Self.maximumMessage,
                          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          self?.send(message, clientID: id, reply: { [weak client] in client?.send($0) }) != nil else { return }
                }
                if buffer.count > Self.maximumMessage { return }
            }
        }
    }

    private func disconnect(_ id: UUID, client: Client) {
        condition.lock()
        clients.removeValue(forKey: id)
        // Keep in-flight browser attaches until their reply arrives, so an
        // abruptly disconnected workerd cannot leave a browser session behind.
        pending = pending.filter { $0.value.clientID != id || $0.value.method == "Target.attachToBrowserTarget" }
        condition.unlock()
        for sessionID in client.sessionIDs {
            send(["id": 0, "method": "Target.detachFromTarget", "params": ["sessionId": sessionID]]) { _ in }
        }
    }

    private final class Client: @unchecked Sendable {
        private let descriptor: Int32
        private let queue = DispatchQueue(label: "dev.xe.cdp.write")
        private let lock = NSLock()
        private var stopped = false
        private var sessions = Set<String>()
        private var queuedBytes = 0
        init(descriptor: Int32) { self.descriptor = descriptor }
        var sessionIDs: Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return sessions
        }
        func addSession(_ sessionID: String) {
            lock.lock()
            sessions.insert(sessionID)
            lock.unlock()
        }
        func stop() {
            lock.lock()
            if !stopped { stopped = true; shutdown(descriptor, SHUT_RDWR) }
            lock.unlock()
        }
        func finish() {
            stop()
            queue.async { close(self.descriptor) }
        }
        func send(_ message: Data) {
            lock.lock()
            guard !stopped, queuedBytes + message.count <= CDPTransport.maximumMessage else {
                if !stopped { stopped = true; shutdown(descriptor, SHUT_RDWR) }
                lock.unlock()
                return
            }
            queuedBytes += message.count
            lock.unlock()
            queue.async {
                defer {
                    self.lock.lock()
                    self.queuedBytes -= message.count
                    self.lock.unlock()
                }
                var data = message
                data.append(0)
                var sent = 0
                let deadline = Date().addingTimeInterval(5)
                while sent < data.count, Date() < deadline {
                    self.lock.lock()
                    let stopped = self.stopped
                    self.lock.unlock()
                    if stopped { return }
                    var pfd = pollfd(fd: self.descriptor, events: Int16(POLLOUT), revents: 0)
                    if poll(&pfd, 1, 100) < 0 { break }
                    let count = data.withUnsafeBytes {
                        Darwin.send(self.descriptor, $0.baseAddress!.advanced(by: sent), data.count - sent, MSG_DONTWAIT)
                    }
                    if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                    if count <= 0 { break }
                    sent += count
                }
                if sent != data.count { self.stop() }
            }
        }
    }

    private final class ReplyBox: @unchecked Sendable {
        private let condition = NSCondition()
        private var data: Data?
        func set(_ data: Data) {
            condition.lock()
            self.data = data
            condition.signal()
            condition.unlock()
        }
        func wait(timeout: TimeInterval) -> Data? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while data == nil { if !condition.wait(until: deadline) { break } }
            return data
        }
    }
}
