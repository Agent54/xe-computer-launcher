import Foundation
import Darwin
import ServiceManagement
@preconcurrency import XPC

enum PrivilegedPortError: LocalizedError {
    case approvalRequired
    case unavailable
    case denied
    case invalidSocket

    var errorDescription: String? {
        switch self {
        case .approvalRequired: "Approve the Xe Launcher port helper in System Settings, then restart the launcher."
        case .unavailable: "The Xe Launcher port helper is unavailable."
        case .denied: "The Xe Launcher port helper refused the socket request."
        case .invalidSocket: "The port helper returned a socket that is not bound to loopback port 80 or 443."
        }
    }
}

struct PrivilegedPortSockets: @unchecked Sendable {
    let http: FileHandle
    let https: FileHandle
}

private final class PortReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PrivilegedPortSockets, Error>?
    private let connection: xpc_connection_t

    init(connection: xpc_connection_t, continuation: CheckedContinuation<PrivilegedPortSockets, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<PrivilegedPortSockets, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        xpc_connection_cancel(connection)
        pending.resume(with: result)
    }
}

enum PrivilegedPortService {
    static let plistName = "dev.xe.computer.ports.plist"
    static let serviceName = "dev.xe.computer.ports"

    static var status: SMAppService.Status {
        SMAppService.daemon(plistName: plistName).status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registration is system-mediated and requires an administrator's approval.
    /// This is only called when an app route uses a standard privileged port.
    static func registerIfNeeded() -> String? {
        let service = SMAppService.daemon(plistName: plistName)
        if service.status == .notRegistered {
            do { try service.register() }
            catch { return "Port helper registration failed: \(error.localizedDescription)" }
        }
        switch service.status {
        case .enabled: return nil
        case .requiresApproval: return "Approve the Xe Launcher port helper in System Settings, then restart the launcher."
        case .notRegistered: return "The Xe Launcher port helper is not registered."
        case .notFound: return "The Xe Launcher port helper is missing from this app bundle."
        @unknown default: return "The Xe Launcher port helper is unavailable."
        }
    }

    static func unregisterIfRegistered() -> String? {
        let service = SMAppService.daemon(plistName: plistName)
        guard service.status == .enabled || service.status == .requiresApproval else { return nil }
        do { try service.unregister(); return nil }
        catch { return "Port helper removal failed: \(error.localizedDescription)" }
    }

    static func acquire() async throws -> PrivilegedPortSockets {
        guard status == .enabled else { throw PrivilegedPortError.approvalRequired }
        return try await withCheckedThrowingContinuation { continuation in
            let connection = serviceName.withCString {
                xpc_connection_create_mach_service($0, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
            }
            let gate = PortReplyGate(connection: connection, continuation: continuation)
            xpc_connection_set_event_handler(connection) { event in
                if xpc_get_type(event) == XPC_TYPE_ERROR {
                    gate.finish(.failure(PrivilegedPortError.unavailable))
                }
            }
            xpc_connection_resume(connection)
            let request = xpc_dictionary_create_empty()
            xpc_dictionary_set_string(request, "operation", "acquire")
            xpc_connection_send_message_with_reply(connection, request, DispatchQueue.global()) { reply in
                do { gate.finish(.success(try sockets(from: reply))) }
                catch { gate.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
                gate.finish(.failure(PrivilegedPortError.unavailable))
            }
        }
    }

    private static func sockets(from reply: xpc_object_t) throws -> PrivilegedPortSockets {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else { throw PrivilegedPortError.unavailable }
        guard let status = xpc_dictionary_get_string(reply, "status"),
              String(cString: status) == "ok" else { throw PrivilegedPortError.denied }
        guard xpc_dictionary_get_int64(reply, "version") == 1 else { throw PrivilegedPortError.unavailable }
        let http = xpc_dictionary_dup_fd(reply, "http")
        let https = xpc_dictionary_dup_fd(reply, "https")
        guard http >= 0, https >= 0 else {
            if http >= 0 { close(http) }
            if https >= 0 { close(https) }
            throw PrivilegedPortError.unavailable
        }
        guard isLoopbackSocket(http, port: 80), isLoopbackSocket(https, port: 443) else {
            close(http)
            close(https)
            throw PrivilegedPortError.invalidSocket
        }
        return PrivilegedPortSockets(http: FileHandle(fileDescriptor: http, closeOnDealloc: true),
                                     https: FileHandle(fileDescriptor: https, closeOnDealloc: true))
    }

    private static func isLoopbackSocket(_ descriptor: Int32, port: UInt16) -> Bool {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return found == 0 && address.sin_family == AF_INET &&
            address.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian && address.sin_port.bigEndian == port
    }
}
