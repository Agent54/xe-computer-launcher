import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct DarcBundleManagerTests {
    private let expected = darcTestBundle(version: "0.0.20")

    @Test func sourceChecksumControlsCacheAndPublication() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("darc/0.0.20/darc.swbn")
        let download = root.appendingPathComponent("download.swbn")
        let checksum = darcTestChecksum(expected)
        try write(darcTestBundle(version: "0.0.19"), to: download)
        #expect(throws: (any Error).self) {
            try installDarcSource(from: download, at: source, expectedSHA256: checksum)
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        try write(expected, to: download)
        try installDarcSource(from: download, at: source, expectedSHA256: checksum)
        #expect(cachedDarcSource(at: source, expectedSHA256: checksum) == source)
        var damaged = expected
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: source)
        #expect(cachedDarcSource(at: source, expectedSHA256: checksum) == nil)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func activatesOnlyMatchingProfilesAndDerivesCurrentState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("darc/0.0.20/darc.swbn")
        let first = root.appendingPathComponent("profiles/default/Default/iwa/first/main.swbn")
        let second = root.appendingPathComponent("profiles/default/Default/iwa/second/main.swbn")
        let foreign = root.appendingPathComponent("profiles/default/Default/iwa/foreign/main.swbn")
        let unrelated = darcTestBundle(version: "9.9.9", identity: String(repeating: "a", count: 56))
        try write(expected, to: source)
        for file in [first, second] { try write(darcTestBundle(version: "0.0.19"), to: file) }
        try write(unrelated, to: foreign)
        let checksum = darcTestChecksum(expected)
        let summary = try activateDarcBundle(sourceURL: source, expectedVersion: "0.0.20", expectedSHA256: checksum, dataURL: root)
        #expect(summary.activatedProfiles == ["default"])
        #expect(summary.failedProfiles.isEmpty)
        for file in [first, second] { #expect(try Data(contentsOf: file) == expected) }
        #expect(try Data(contentsOf: foreign) == unrelated)
        #expect(activeDarcBundleActivation(dataURL: root, profileName: "default", sourceURL: source,
                                          expectedVersion: "0.0.20", expectedSHA256: checksum)?.sha256 == checksum)
        let again = try activateDarcBundle(sourceURL: source, expectedVersion: "0.0.20", expectedSHA256: checksum, dataURL: root)
        #expect(again.activatedProfiles.isEmpty)
        #expect(again.verifiedProfiles == ["default"])
    }

    @Test func atomicallyReplacesCorruptBundleWithExistingShim() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("darc/0.0.20/darc.swbn")
        let installed = root.appendingPathComponent("profiles/default/Default/iwa/app/main.swbn")
        let shim = root.appendingPathComponent("shims/default/Xe Computer.app")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        try write(expected, to: source)
        var corrupt = expected
        corrupt[corrupt.count - 1] ^= 1
        try write(corrupt, to: installed)
        let oldInode = root.appendingPathComponent("old-inode")
        try FileManager.default.linkItem(at: installed, to: oldInode)
        let result = try activateDarcBundle(sourceURL: source, expectedVersion: "0.0.20",
                                            expectedSHA256: darcTestChecksum(expected), dataURL: root)
        #expect(result.activatedProfiles == ["default"])
        #expect(try Data(contentsOf: installed) == expected)
        #expect(try Data(contentsOf: oldInode) == corrupt)
        #expect(FileManager.default.fileExists(atPath: shim.path))
        #expect(getxattr(installed.deletingLastPathComponent().path, "dev.xe.darc.bundle-id", nil, 0, 0, 0) == -1)
    }

    @Test func corruptSourceCannotReplaceWorkingProfile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("darc.swbn")
        let installed = root.appendingPathComponent("profiles/default/Default/iwa/app/main.swbn")
        try write(expected, to: installed)
        try write(expected + Data([0]), to: source)
        #expect(throws: (any Error).self) {
            try activateDarcBundle(sourceURL: source, expectedVersion: "0.0.20",
                                   expectedSHA256: darcTestChecksum(expected), dataURL: root)
        }
        #expect(try Data(contentsOf: installed) == expected)
    }

    @Test func configuredPinRequiresChecksum() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Launcher.bundle/Contents/Resources")
        let config = resources.appendingPathComponent("sources.json")
        let source = root.appendingPathComponent("darc/0.0.20/darc.swbn")
        try write(expected, to: source)
        try write(Data(#"{"darc":{"version":{"major":0,"minor":0,"patch":20}}}"#.utf8), to: config)
        let bundle = try #require(Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent()))
        #expect(installedConfiguredDarcSourceURL(dataURL: root, bundle: bundle) == nil)
        let pin: [String: Any] = ["darc": ["version": ["major": 0, "minor": 0, "patch": 20], "sha256": darcTestChecksum(expected)]]
        try JSONSerialization.data(withJSONObject: pin).write(to: config)
        #expect(installedConfiguredDarcSourceURL(dataURL: root, bundle: bundle) == source)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
