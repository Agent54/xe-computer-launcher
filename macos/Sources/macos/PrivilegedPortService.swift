import Foundation
import Darwin
import CryptoKit
import ServiceManagement
import PortHelperSupport
@preconcurrency import XPC

enum PrivilegedPortError: LocalizedError {
    case approvalRequired
    case unavailable
    case denied
    case invalidSocket

    var errorDescription: String? {
        switch self {
        case .approvalRequired: "Approve the Xe Launcher port helper in System Settings; Xe Launcher will detect approval automatically."
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
    private static let approvalMessage = "To use ports 80/443, allow Xe Launcher's background port helper. In the macOS Background Items Added notification choose Options → Allow, or enable Xe Launcher in System Settings → General → Login Items & Extensions. Authenticate as an administrator; Xe Launcher will detect approval automatically."

    static var status: SMAppService.Status {
        SMAppService.daemon(plistName: plistName).status
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Registration is system-mediated and requires an administrator's approval.
    /// This is only called when an app route uses a standard privileged port.
    static func registerIfNeeded(forceRefresh: Bool = false) async -> String? {
        let bundleURL = Bundle.main.bundleURL
        let plistURL = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(plistName)")
        let helperURL = bundleURL.appendingPathComponent("Contents/MacOS/port-helper")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return "The Xe Launcher port helper is missing from this app bundle."
        }
        let fingerprint: String
        do {
            fingerprint = try registrationFingerprint(bundleURL: bundleURL, plistURL: plistURL)
        } catch {
            return "Could not inspect the Xe Launcher port helper: \(error.localizedDescription)"
        }
        let markerURL = ExternalState.appDataURL.appendingPathComponent("workerd/port-helper-registration.sha256")
        let recordedFingerprint = try? String(contentsOf: markerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let service = SMAppService.daemon(plistName: plistName)
        var needsRegistration = service.status == .notRegistered || service.status == .notFound
        // Rebuilds can change code identity without changing helper behavior.
        // Preserve a healthy helper for the same configuration, or adopt one
        // while migrating an older binary-based marker. Never adopt across a
        // known configuration change or an explicit recovery request.
        if await canReuseRegistration(recordedFingerprint: recordedFingerprint,
                                      fingerprint: fingerprint, forceRefresh: forceRefresh,
                                      probe: { await waitUntilReady() }) {
            if recordedFingerprint != fingerprint {
                do { try recordFingerprint(fingerprint, at: markerURL) }
                catch { return "Port helper is active, but its update state could not be saved: \(error.localizedDescription)" }
            }
            return nil
        }
        // SMAppService does not replace an enabled daemon just because the app
        // bundle was updated. Refresh when the required revision/configuration
        // changed, the bounded readiness probe failed, or recovery was requested.
        // Unregister must finish killing the old process first. Keep pending
        // approval intact instead of withdrawing it on each update.
        if service.status == .enabled {
            ExternalState.shared.appendLog("launcher", "Refreshing the port helper registration for the installed Xe Launcher bundle.")
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    service.unregister { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                let removalDeadline = Date().addingTimeInterval(5)
                while (service.status == .enabled || service.status == .requiresApproval),
                      Date() < removalDeadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard service.status == .notRegistered || service.status == .notFound else {
                    return "macOS has not finished removing the previous port helper registration. Choose Try Again once it does."
                }
                needsRegistration = true
            } catch {
                return "Port helper update could not remove the old registration: \(error.localizedDescription)"
            }
        }
        // Service Management can report .notFound before this service has ever
        // been registered, even when both bundle files are present.
        if needsRegistration {
            do { try service.register() }
            catch {
                let failure = error as NSError
                // A first-time daemon registration can throw this error while
                // macOS waits for an administrator to approve the background item.
                if service.status == .requiresApproval ||
                    (failure.domain == SMAppServiceErrorDomain && failure.code == 1) {
                    try? recordFingerprint(fingerprint, at: markerURL)
                    return approvalMessage
                }
                return "Port helper registration failed (\(failure.domain) code \(failure.code)): \(failure.localizedDescription)"
            }
            do { try recordFingerprint(fingerprint, at: markerURL) }
            catch { return "Port helper registered, but its update state could not be saved: \(error.localizedDescription)" }
        }
        switch service.status {
        case .enabled: return nil
        case .requiresApproval: return approvalMessage
        case .notRegistered: return "The Xe Launcher port helper is not registered."
        case .notFound: return "macOS could not find the Xe Launcher port helper service after registration."
        @unknown default: return "The Xe Launcher port helper is unavailable."
        }
    }

    static func canReuseRegistration(recordedFingerprint: String?, fingerprint: String,
                                     forceRefresh: Bool, probe: () async -> Bool) async -> Bool {
        guard !forceRefresh,
              recordedFingerprint == fingerprint || recordedFingerprint?.hasPrefix("config-v1:") != true else {
            return false
        }
        return await probe()
    }

    static func registrationFingerprint(bundleURL: URL, plistURL: URL,
                                        helperRevision: Int64 = PortHelperProtocol.revision) throws -> String {
        var hash = SHA256()
        hash.update(data: Data(bundleURL.resolvingSymlinksInPath().path.utf8))
        hash.update(data: Data("\u{0}\(PortHelperProtocol.version):\(helperRevision)\u{0}".utf8))
        hash.update(data: try Data(contentsOf: plistURL))
        return "config-v1:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func waitUntilReady(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if (try? await acquire()) != nil { return true }
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(250))
        } while true
    }

    private static func recordFingerprint(_ fingerprint: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try fingerprint.write(to: url, atomically: true, encoding: .utf8)
    }

    static func unregisterIfRegistered() -> String? {
        let service = SMAppService.daemon(plistName: plistName)
        guard service.status == .enabled || service.status == .requiresApproval else { return nil }
        do { try service.unregister(); return nil }
        catch { return "Port helper removal failed: \(error.localizedDescription)" }
    }

    static func acquire() async throws -> PrivilegedPortSockets {
        // Service Management's status can lag during an app replacement. The
        // system Mach service and daemon still enforce authorization; a valid
        // socket handoff is the authoritative readiness check.
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
        // Only a helper with the supported socket-handoff protocol may be used.
        guard PortHelperProtocol.supports(version: xpc_dictionary_get_int64(reply, "version"),
                                          revision: xpc_dictionary_get_int64(reply, "revision")) else {
            throw PrivilegedPortError.unavailable
        }
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
