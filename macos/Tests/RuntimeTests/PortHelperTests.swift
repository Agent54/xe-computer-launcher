import Darwin
import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct PortHelperTests {
    @Test func registrationFingerprintUsesCodeIdentity() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = macosRoot.appendingPathComponent(".build/debug/port-helper")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xe-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("port-helper")
        let plist = directory.appendingPathComponent("ports.plist")
        try FileManager.default.copyItem(at: source, to: helper)
        try Data("original service configuration".utf8).write(to: plist)
        let bundle = URL(fileURLWithPath: "/Applications/Xe Launcher.app")
        let original = try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, helperURL: helper, plistURL: plist)
        // Trailing signing-envelope bytes change the old whole-file hash but
        // do not change the executable's CodeDirectory identity.
        let writer = try FileHandle(forWritingTo: helper)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 0, count: 16))
        try writer.close()
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, helperURL: helper, plistURL: plist) == original)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle.appendingPathComponent("moved"), helperURL: helper, plistURL: plist) != original)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, helperURL: URL(fileURLWithPath: "/usr/bin/true"), plistURL: plist) != original)
        try Data("changed service configuration".utf8).write(to: plist)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, helperURL: helper, plistURL: plist) != original)
    }

    @Test func bootstrapPassesBothListenerDescriptorsToWorkerd() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = macosRoot.appendingPathComponent(".build/debug/port-helper")
        try #require(FileManager.default.isExecutableFile(atPath: helper.path))

        func listener() throws -> (FileHandle, UInt16) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            try #require(descriptor >= 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(bound == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let found = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
            }
            try #require(found == 0)
            return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), address.sin_port.bigEndian)
        }
        let (http, httpPort) = try listener()
        let (https, httpsPort) = try listener()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--exec-workerd", helper.path, "--probe-inherited"]
        process.standardInput = http
        process.standardOutput = https
        let logs = Pipe()
        process.standardError = logs
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let output = String(decoding: logs.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output == "\(httpPort),\(httpsPort)\n")
    }
}
