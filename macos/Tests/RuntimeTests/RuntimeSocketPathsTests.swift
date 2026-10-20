import Darwin
import Foundation
import Testing
@testable import macos

struct RuntimeSocketPathsTests {
    private func fixture() throws -> (root: URL, paths: RuntimeSocketPaths) {
        // Actual bind/connect checks need short addresses even in deep CI checkouts.
        let root = URL(fileURLWithPath: "/tmp/xe-run-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appData = home.appendingPathComponent(
            "Library/Application Support/" + String(repeating: "long-app-data-", count: 8), isDirectory: true
        )
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        return (root, RuntimeSocketPaths(homeURL: home, appDataURL: appData))
    }

    @Test func acceptsTheCIHomeAndRejectsLongPathsBeforeCreatingState() throws {
        let paths = RuntimeSocketPaths(
            homeURL: URL(fileURLWithPath: "/Users/github-actions-runner", isDirectory: true),
            appDataURL: URL(fileURLWithPath: "/Users/github-actions-runner/Library/Application Support/dev.xe.computer")
        )
        try paths.validate()
        #expect(paths.composeSocketURL.path == "/Users/github-actions-runner/.xe/run/compose.sock")

        let (root, fixturePaths) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tooLong = RuntimeSocketPaths(
            homeURL: fixturePaths.homeURL.appendingPathComponent(String(repeating: "x", count: 100)),
            appDataURL: fixturePaths.appDataURL
        )
        #expect(throws: RuntimeSocketPathError.self) { try tooLong.prepare() }
        #expect(!FileManager.default.fileExists(atPath: tooLong.homeURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixturePaths.directoryURL.path))
    }

    @Test func countsUTF8BytesAndAllowsTheExactSocketLimit() throws {
        try RuntimeSocketPaths.validateSocketPath(URL(fileURLWithPath: "/" + String(repeating: "x", count: 102)))
        try RuntimeSocketPaths.validateSocketPath(URL(fileURLWithPath: "/" + String(repeating: "界", count: 34)))
        do {
            try RuntimeSocketPaths.validateSocketPath(URL(fileURLWithPath: "/" + String(repeating: "界", count: 35)))
            Issue.record("A 106-byte path must not fit in sun_path")
        } catch RuntimeSocketPathError.tooLong(_, let bytes, let maximum) {
            #expect(bytes == 106)
            #expect(maximum == 103)
        }
    }

    @Test func aliasesExistingDataPrivatelyAndSurvivesCIDataCleanup() throws {
        let (root, paths) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = paths.appDataURL.appendingPathComponent("existing-disk.raw")
        let contents = Data("existing VM data".utf8)
        try contents.write(to: disk)
        try paths.prepare()
        try paths.prepare()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: paths.directoryURL.path) == paths.appDataURL.path)
        #expect(try Data(contentsOf: paths.directoryURL.appendingPathComponent(disk.lastPathComponent)) == contents)
        for directory in [paths.homeURL.appendingPathComponent(".xe"), paths.appDataURL,
                          paths.smolDataURL, paths.socketsURL, paths.workerdDirectoryURL, paths.browserSocketsURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            #expect(attributes[.posixPermissions] as? Int == 0o700)
        }
        // CI removes app data but retains the alias in this user's home.
        try FileManager.default.removeItem(at: paths.appDataURL)
        try paths.prepare()
        #expect(FileManager.default.fileExists(atPath: paths.socketsURL.path))
    }

    @Test func refusesUnrelatedRunItemsAndSymlinkedPrivateDirectories() throws {
        let (root, paths) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        let privateURL = paths.homeURL.appendingPathComponent(".xe")
        let unrelated = root.appendingPathComponent("unrelated")
        try fileManager.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unrelated.path)
        try fileManager.createSymbolicLink(at: privateURL, withDestinationURL: unrelated)
        #expect(throws: RuntimeSocketPathError.self) { try paths.prepare() }
        let attributes = try fileManager.attributesOfItem(atPath: unrelated.path)
        #expect(attributes[.posixPermissions] as? Int == 0o755)
        try fileManager.removeItem(at: privateURL)
        try fileManager.createDirectory(at: privateURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: paths.directoryURL, withDestinationURL: unrelated)
        #expect(throws: RuntimeSocketPathError.self) { try paths.prepare() }
        #expect(try fileManager.destinationOfSymbolicLink(atPath: paths.directoryURL.path) == unrelated.path)
        try fileManager.removeItem(at: paths.directoryURL)
        let contents = Data("keep this file".utf8)
        try contents.write(to: paths.directoryURL)
        #expect(throws: RuntimeSocketPathError.self) { try paths.prepare() }
        #expect(try Data(contentsOf: paths.directoryURL) == contents)
    }

    @Test func bindsAndConnectsThroughTheAliasToAnOverlongPhysicalPath() throws {
        let (root, paths) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.prepare()
        let machineURL = VMResourceSampler.machineDirectory(named: SmolVMSetup.machineName, dataURL: paths.smolDataURL)
        try FileManager.default.createDirectory(at: machineURL, withIntermediateDirectories: true)
        let socketURL = machineURL.appendingPathComponent("control.sock")
        let oldURL = paths.appDataURL.appendingPathComponent("smol/\(machineURL.lastPathComponent)/control.sock")
        #expect(oldURL.path.utf8.count > 103)
        try RuntimeSocketPaths.validateSocketPath(socketURL)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketURL.path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
    }
}
