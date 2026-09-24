import Foundation
import Darwin
@preconcurrency import XPC

private let serviceName = "dev.xe.computer.ports"

private func activatedSocket(_ name: String, port: UInt16) -> Int32 {
    var descriptors: UnsafeMutablePointer<Int32>?
    var count = 0
    let result = withUnsafeMutablePointer(to: &descriptors) { pointer in
        pointer.withMemoryRebound(to: UnsafeMutablePointer<Int32>.self, capacity: 1) {
            rebound in name.withCString { launch_activate_socket($0, rebound, &count) }
        }
    }
    guard result == 0, count == 1, let descriptors else {
        fputs("port-helper: launchd socket \(name) unavailable (\(result), count \(count))\n", stderr)
        exit(1)
    }
    let descriptor = descriptors[0]
    free(descriptors)
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let found = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard found == 0, address.sin_family == AF_INET,
          address.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian,
          address.sin_port.bigEndian == port else {
        fputs("port-helper: launchd socket \(name) is not 127.0.0.1:\(port)\n", stderr)
        exit(1)
    }
    return descriptor
}

private func executablePath(pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: 4096)
    let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
    guard length > 0 else { return nil }
    let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().path
}

private func authorizedLauncher(_ peer: xpc_connection_t) -> Bool {
    // A system daemon is shared by all users. Only the current console user’s
    // exact launcher executable may receive the listening descriptors.
    var console = stat()
    guard stat("/dev/console", &console) == 0,
          console.st_uid != 0, xpc_connection_get_euid(peer) == console.st_uid else { return false }
    let pid = xpc_connection_get_pid(peer)
    guard pid > 0 else { return false }
    guard let caller = executablePath(pid: pid), let helper = executablePath(pid: getpid()) else { return false }
    let expected = URL(fileURLWithPath: helper)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MacOS/bin").path
    return caller == expected
}

private func runDaemon() -> Never {
    let http = activatedSocket("ingest", port: 80)
    let https = activatedSocket("tls", port: 443)
    let listener = serviceName.withCString {
        xpc_connection_create_mach_service($0, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    }
    xpc_connection_set_event_handler(listener) { peer in
        guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
        xpc_connection_set_event_handler(peer) { message in
            guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                  let reply = xpc_dictionary_create_reply(message) else { return }
            if authorizedLauncher(peer),
               let operation = xpc_dictionary_get_string(message, "operation"),
               String(cString: operation) == "acquire" {
                xpc_dictionary_set_fd(reply, "http", http)
                xpc_dictionary_set_fd(reply, "https", https)
                xpc_dictionary_set_int64(reply, "version", 2)
                xpc_dictionary_set_string(reply, "status", "ok")
            } else {
                xpc_dictionary_set_string(reply, "status", "denied")
            }
            xpc_connection_send_message(peer, reply)
        }
        xpc_connection_resume(peer)
    }
    xpc_connection_resume(listener)
    dispatchMain()
}

private func execWorkerd(_ arguments: [String]) -> Never {
    guard let worker = arguments.first, arguments.count > 1 else { exit(64) }
    // Foundation Process can reliably pass two sockets as stdin/stdout. Move
    // them to stable non-stdio descriptors before exec, restoring output logs.
    let http = fcntl(STDIN_FILENO, F_DUPFD, 5)
    let https = fcntl(STDOUT_FILENO, F_DUPFD, 5)
    guard http >= 0, https >= 0,
          dup2(http, 3) == 3, dup2(https, 4) == 4 else { exit(71) }
    close(http)
    close(https)
    let null = open("/dev/null", O_RDONLY)
    guard null >= 0, dup2(null, STDIN_FILENO) == STDIN_FILENO,
          dup2(STDERR_FILENO, STDOUT_FILENO) == STDOUT_FILENO else { exit(71) }
    close(null)
    let argv = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    _ = argv.withUnsafeBufferPointer { buffer in
        worker.withCString { execv($0, buffer.baseAddress) }
    }
    fputs("port-helper: exec workerd failed: \(String(cString: strerror(errno)))\n", stderr)
    exit(71)
}

private func probeInheritedSockets() -> Never {
    func port(_ descriptor: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        return found == 0 && address.sin_family == AF_INET ? address.sin_port.bigEndian : nil
    }
    guard let http = port(3), let https = port(4) else { exit(71) }
    fputs("\(http),\(https)\n", stderr)
    exit(0)
}

if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--exec-workerd" {
    execWorkerd(Array(CommandLine.arguments.dropFirst(2)))
} else if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--probe-inherited" {
    probeInheritedSockets()
} else if CommandLine.arguments.count == 1 {
    runDaemon()
} else {
    exit(64)
}
