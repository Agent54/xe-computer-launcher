import Darwin
import Foundation

/// A short spelling of the existing app-data tree. Never resolve this alias
/// before passing a socket address or SMOLVM_DATA_DIR to a subprocess.
struct RuntimeSocketPaths {
    static let shared = RuntimeSocketPaths(
        homeURL: FileManager.default.homeDirectoryForCurrentUser,
        appDataURL: ExternalState.appDataURL
    )

    let homeURL: URL
    let appDataURL: URL

    var directoryURL: URL { homeURL.appendingPathComponent(".xe/run", isDirectory: true) }
    var smolDataURL: URL { directoryURL.appendingPathComponent("smol", isDirectory: true) }
    var socketsURL: URL { smolDataURL.appendingPathComponent("sockets", isDirectory: true) }
    var composeSocketURL: URL { directoryURL.appendingPathComponent("compose.sock") }
    var workerdDirectoryURL: URL { directoryURL.appendingPathComponent("workerd", isDirectory: true) }
    var browserSocketsURL: URL { directoryURL.appendingPathComponent("sockets", isDirectory: true) }

    static func validateSocketPath(_ url: URL) throws {
        let maximum = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        let length = url.path.utf8.count
        guard length <= maximum else {
            throw RuntimeSocketPathError.tooLong(path: url.path, bytes: length, maximum: maximum)
        }
    }

    static func validateSmolPaths(dataURL: URL) throws {
        let machineURL = VMResourceSampler.machineDirectory(named: SmolVMSetup.machineName, dataURL: dataURL)
        for name in ["agent.sock", "control.sock", "dns-filter.sock"] {
            try validateSocketPath(machineURL.appendingPathComponent(name))
        }
    }

    static func validateWorkerdPaths(directoryURL: URL) throws {
        for name in ["u-00000000.sock", "s-00000000.sock"] {
            try validateSocketPath(directoryURL.appendingPathComponent(name))
        }
    }

    func validate() throws {
        try Self.validateSocketPath(composeSocketURL)
        for name in ["docker.sock", "workerd.sock", "maintenance.sock"] {
            try Self.validateSocketPath(socketsURL.appendingPathComponent(name))
        }
        try Self.validateSmolPaths(dataURL: smolDataURL)
        try Self.validateWorkerdPaths(directoryURL: workerdDirectoryURL)
        try Self.validateSocketPath(browserSocketsURL.appendingPathComponent("chrome-debug.sock"))
    }

    func prepare() throws {
        // Fail before creating state, opening listeners, or starting a VM.
        try validate()
        let fileManager = FileManager.default
        try Self.preparePrivateDirectory(homeURL.appendingPathComponent(".xe", isDirectory: true))
        try Self.preparePrivateDirectory(appDataURL)

        var metadata = stat()
        if lstat(directoryURL.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFLNK,
                  metadata.st_uid == getuid(),
                  try fileManager.destinationOfSymbolicLink(atPath: directoryURL.path) == appDataURL.path else {
                throw RuntimeSocketPathError.unsafeLocation(directoryURL.path)
            }
        } else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try fileManager.createSymbolicLink(at: directoryURL, withDestinationURL: appDataURL)
        }

        // These remain real directories at their original locations. The short
        // alias also preserves persisted VM socket mappings and existing disks.
        let smolURL = appDataURL.appendingPathComponent("smol", isDirectory: true)
        try Self.preparePrivateDirectory(smolURL)
        try Self.preparePrivateDirectory(smolURL.appendingPathComponent("sockets", isDirectory: true))
        try Self.preparePrivateDirectory(appDataURL.appendingPathComponent("workerd", isDirectory: true))
        try Self.preparePrivateDirectory(appDataURL.appendingPathComponent("sockets", isDirectory: true))
    }

    private static func preparePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Inspect and chmod the opened directory itself; never follow a
        // substituted symlink or change permissions on an unrelated target.
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw RuntimeSocketPathError.unsafeLocation(url.path) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid() else {
            throw RuntimeSocketPathError.unsafeLocation(url.path)
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

enum RuntimeSocketPathError: LocalizedError {
    case tooLong(path: String, bytes: Int, maximum: Int)
    case unsafeLocation(String)

    var errorDescription: String? {
        switch self {
        case .tooLong(let path, let bytes, let maximum):
            return "The runtime socket path is \(bytes) UTF-8 bytes; macOS allows at most \(maximum): \(path). Use a shorter home-directory path before restarting Xe Launcher."
        case .unsafeLocation(let path):
            return "The runtime location is not an owned private directory or the expected launcher symlink: \(path). Move the conflicting item before restarting Xe Launcher."
        }
    }
}
