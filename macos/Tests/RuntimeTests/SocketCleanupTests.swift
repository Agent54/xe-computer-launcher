import Darwin
import Foundation
import Testing
@testable import macos

struct SocketCleanupTests {
    @Test func preservesFilesDirectoriesAndSymlinksAtSocketPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.sock")
        try Data("keep".utf8).write(to: file)
        let directory = root.appendingPathComponent("directory.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let link = root.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        for url in [file, directory, link] {
            #expect(throws: SmolVMSetupError.self) { try SmolVMSetup.removeSocketIfPresent(at: url) }
        }
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == directory.path)
        try SmolVMSetup.removeSocketIfPresent(at: root.appendingPathComponent("missing.sock"))
    }

    @Test func removesOnlyAnActualSocket() throws {
        // Unix socket paths must fit macOS's 104-byte sockaddr_un limit.
        let root = URL(fileURLWithPath: "/tmp/xe-sock-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.sock")
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0)
        try SmolVMSetup.removeSocketIfPresent(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
