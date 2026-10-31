import Foundation
import Darwin

package struct MaintenanceFailure: LocalizedError {
    package let errorDescription: String?
    package init(_ message: String) { errorDescription = message }
}

package struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    static func read(_ descriptor: Int32) throws -> FileIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixFailure() }
        return FileIdentity(metadata)
    }
}

package func posixFailure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

/// Walk every ancestor without following links. Keep the final directory open;
/// mutations use *at syscalls against it, never a newly resolved absolute path.
package final class AnchoredDirectory {
    package struct Identity: Codable, Equatable, Sendable {
        package let path: String
        package let ancestors: [FileIdentity]
    }

    package let descriptor: Int32
    package let identity: Identity
    package var url: URL { URL(fileURLWithPath: identity.path, isDirectory: true) }

    package init(_ url: URL, create: Bool = false, expected: Identity? = nil) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else {
            throw MaintenanceFailure("Invalid directory path.")
        }
        // Foundation standardization rewrites /private/var to the /var
        // symlink on macOS. Keep the literal absolute path for no-follow walks.
        let path = "/" + url.path.split(separator: "/").map(String.init).joined(separator: "/")
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw posixFailure() }
        var ancestors: [FileIdentity] = []
        do {
            ancestors.append(try FileIdentity.read(current))
            for name in path.split(separator: "/").map(String.init) {
                if create, mkdirat(current, name, 0o700) != 0, errno != EEXIST { throw posixFailure() }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw posixFailure() }
                close(current)
                current = next
                ancestors.append(try FileIdentity.read(current))
            }
            let identity = Identity(path: path, ancestors: ancestors)
            guard expected == nil || identity == expected else {
                throw MaintenanceFailure("A directory or one of its ancestors changed: \(path)")
            }
            self.identity = identity
            descriptor = current
        } catch {
            close(current)
            throw error
        }
    }

    deinit { close(descriptor) }

    package init(childOf parent: AnchoredDirectory, name: String, create: Bool = false) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { throw MaintenanceFailure("Invalid directory name.") }
        try parent.validate()
        if create, mkdirat(parent.descriptor, name, 0o700) != 0, errno != EEXIST { throw posixFailure() }
        let fd = openat(parent.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        do {
            identity = Identity(path: parent.url.appendingPathComponent(name).path,
                                ancestors: parent.identity.ancestors + [try FileIdentity.read(fd)])
            descriptor = fd
        } catch { close(fd); throw error }
    }

    package func validate() throws {
        _ = try AnchoredDirectory(url, expected: identity)
        guard try FileIdentity.read(descriptor) == identity.ancestors.last else {
            throw MaintenanceFailure("Directory identity changed: \(identity.path)")
        }
    }

    package func requirePrivateOwner() throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixFailure() }
        guard metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw MaintenanceFailure("The directory must be owned by this user and not writable by others: \(identity.path)")
        }
    }

    package func names() throws -> [String] {
        // openat creates an independent directory offset (dup would share it).
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw posixFailure() }
        guard let stream = fdopendir(copy) else { close(copy); throw posixFailure() }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixFailure() }
                return names.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    package func entryIdentity(_ name: String) throws -> FileIdentity {
        var metadata = stat()
        guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        return FileIdentity(metadata)
    }

    package func move(_ name: String, to destination: AnchoredDirectory, as destinationName: String) throws {
        guard renameatx_np(descriptor, name, destination.descriptor, destinationName, UInt32(RENAME_EXCL)) == 0 else {
            throw posixFailure()
        }
    }
}

/// Stored outside app data, so archival never moves or replaces the lock file.
/// The helper inherits the very same open file description and its flock.
package final class LauncherLifecycle {
    package let directory: AnchoredDirectory
    package private(set) var descriptor: Int32
    private let fileIdentity: FileIdentity

    package static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
            .appendingPathComponent("Library/Application Support/.dev.xe.computer-lifecycle", isDirectory: true)
    }

    package init(directoryURL: URL = LauncherLifecycle.directoryURL, inherited: Int32? = nil) throws {
        directory = try AnchoredDirectory(directoryURL, create: inherited == nil)
        try directory.requirePrivateOwner()
        let fd = inherited.map { fcntl($0, F_DUPFD_CLOEXEC, 3) }
            ?? openat(directory.descriptor, "lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }
        do {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else { throw posixFailure() }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0, metadata.st_nlink == 1,
                  FileIdentity(metadata) == (try directory.entryIdentity("lock")) else {
                throw MaintenanceFailure("The launcher lifecycle lock was replaced or is unsafe.")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw MaintenanceFailure("Another Xe Launcher is running or completing maintenance.")
            }
            descriptor = fd
            fileIdentity = FileIdentity(metadata)
        } catch { close(fd); throw error }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }

    package func release() {
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
    }

    package func validate() throws {
        try directory.validate()
        guard try directory.entryIdentity("lock") == fileIdentity else {
            throw MaintenanceFailure("The launcher lifecycle lock was replaced.")
        }
    }
}
