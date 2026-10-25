import Darwin
import Foundation
import PortHelperSupport
import Testing
@testable import macos

@Suite(.serialized)
struct PortHelperTests {
    @Test func registrationFingerprintTracksConfigurationAndRequiredRevision() throws {
        let macosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = macosRoot.appendingPathComponent(".build/port-helper-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist = directory.appendingPathComponent("ports.plist")
        try Data("original service configuration".utf8).write(to: plist)
        let bundle = URL(fileURLWithPath: "/Applications/Xe Launcher.app")
        let original = try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, plistURL: plist)
        #expect(original.hasPrefix("config-v1:"))
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, plistURL: plist) == original)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle.appendingPathComponent("moved"), plistURL: plist) != original)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, plistURL: plist,
                                                                 helperRevision: PortHelperProtocol.revision + 1) != original)
        try Data("changed service configuration".utf8).write(to: plist)
        #expect(try PrivilegedPortService.registrationFingerprint(bundleURL: bundle, plistURL: plist) != original)
    }

    @Test func registrationReuseRequiresHealthyCompatibleHelper() async {
        let fingerprint = "config-v1:current"
        let cases: [(recorded: String?, force: Bool, ready: Bool, reusable: Bool, probes: Bool)] = [
            (nil, false, true, true, true),
            (String(repeating: "0", count: 64), false, true, true, true),
            ("cdhash-v1:previous-build", false, true, true, true),
            (fingerprint, false, true, true, true),
            ("config-v1:previous-configuration", false, true, false, false),
            (fingerprint, true, true, false, false),
            ("cdhash-v1:previous-build", true, true, false, false),
            ("cdhash-v1:previous-build", false, false, false, true),
            (fingerprint, false, false, false, true)
        ]
        for item in cases {
            var probed = false
            let reusable = await PrivilegedPortService.canReuseRegistration(
                recordedFingerprint: item.recorded, fingerprint: fingerprint, forceRefresh: item.force
            ) {
                probed = true
                return item.ready
            }
            #expect(reusable == item.reusable)
            #expect(probed == item.probes)
        }
    }

    @Test func helperRevisionMustMatchRequiredBehavior() {
        #expect(PortHelperProtocol.supports(version: PortHelperProtocol.version, revision: PortHelperProtocol.revision))
        #expect(!PortHelperProtocol.supports(version: PortHelperProtocol.version + 1, revision: PortHelperProtocol.revision))
        #expect(!PortHelperProtocol.supports(version: PortHelperProtocol.version, revision: PortHelperProtocol.revision + 1))
        #expect(PortHelperProtocol.supports(version: PortHelperProtocol.version, revision: 0) == (PortHelperProtocol.revision == 1))
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
