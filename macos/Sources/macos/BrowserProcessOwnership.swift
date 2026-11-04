import Darwin
import Foundation

enum BrowserProcessOwnership {
    struct ProcessSnapshot {
        let pid: pid_t
        let group: pid_t
        let executable: String
        let arguments: [String]
    }

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func contains(_ path: String, in directory: URL) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let root = normalizedPath(directory)
        return normalizedPath(URL(fileURLWithPath: path)).hasPrefix(root + "/")
    }

    static func matchesShim(bundleURL: URL?, executableURL: URL?, expectedAppURL: URL) -> Bool {
        // Prefer the running executable: Launch Services may retain a stale
        // bundle URL after provisioning moves a shim. Bundle IDs are shared by
        // copies of the same IWA, including older Darc installations.
        if let executableURL {
            return normalizedPath(executableURL) == normalizedPath(
                expectedAppURL.appendingPathComponent("Contents/MacOS/app_mode_loader")
            )
        }
        return bundleURL.map(normalizedPath) == normalizedPath(expectedAppURL)
    }

    static func userDataDirectory(arguments: [String]) -> String? {
        var directory: String?
        for argument in arguments.dropFirst() {
            if argument == "--" { break }
            if argument.hasPrefix("--user-data-dir=") {
                directory = String(argument.dropFirst("--user-data-dir=".count))
            }
            if argument == "--user-data-dir" { directory = "" }
        }
        return directory
    }

    static func ownsBrowser(arguments: [String], dataURL: URL) -> Bool {
        guard let profile = userDataDirectory(arguments: arguments) else { return false }
        return contains(profile, in: dataURL.appendingPathComponent("profiles", isDirectory: true))
    }

    static func staleProcesses(_ processes: [ProcessSnapshot], dataURL: URL,
                               ownPID: pid_t, browserGroup: pid_t) -> [ProcessSnapshot] {
        let candidates = processes.filter {
            $0.pid != ownPID && $0.pid != browserGroup && (browserGroup <= 0 || $0.group != browserGroup)
        }
        func isBrowser(_ process: ProcessSnapshot) -> Bool {
            ExternalState.isPrivateBrowserExecutable(process.executable, dataURL: dataURL)
                || ["Helium", "Chromium", "Google Chrome", "Google Chrome Canary"].contains {
                    process.executable.hasSuffix("/" + $0)
                }
        }
        // Only an owned browser leading its own group proves that the group
        // is dedicated to it; a shared shell/Launch Services group does not.
        let ownedGroups = Set(candidates.filter {
            $0.pid == $0.group && isBrowser($0) && ownsBrowser(arguments: $0.arguments, dataURL: dataURL)
        }.map(\.group))
        return candidates.filter { process in
            if process.executable.hasSuffix("/app_mode_loader") {
                return contains(process.executable, in: dataURL.appendingPathComponent("shims"))
            }
            guard isBrowser(process) else { return false }
            if userDataDirectory(arguments: process.arguments) != nil {
                return ownsBrowser(arguments: process.arguments, dataURL: dataURL)
            }
            return ExternalState.isPrivateBrowserExecutable(process.executable, dataURL: dataURL)
                && ownedGroups.contains(process.group)
        }
    }

    static func executableURL(pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }

    static func arguments(pid: pid_t) -> [String]? {
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return decodeArguments(Array(buffer.prefix(size)))
    }

    // KERN_PROCARGS2 contains argc, the executable path, padding, argv, then
    // environment strings. Preserve argv boundaries; ps flattens paths with
    // spaces and can mistake text in another argument for --user-data-dir.
    static func decodeArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= bytes.count else { return nil }
        var offset = MemoryLayout<Int32>.size
        guard let executableEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = executableEnd
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                  let argument = String(bytes: bytes[offset..<end], encoding: .utf8) else { return nil }
            arguments.append(argument)
            offset = end + 1
        }
        return arguments
    }
}
