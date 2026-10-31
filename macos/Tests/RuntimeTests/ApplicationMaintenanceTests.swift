import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct ApplicationMaintenanceTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/xe-maintenance-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func archivesAllDataAndPreservesEarlierArchivesAndExternalStorage() throws {
        let fm = FileManager.default
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let dataURL = root.appendingPathComponent("app data")
        let previous = dataURL.appendingPathComponent("archive/previous")
        let external = root.appendingPathComponent("external projects")
        for directory in [previous, external, dataURL.appendingPathComponent("profiles/default"), dataURL.appendingPathComponent("smol")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let settings = Data("{\"run_at_startup\":true}".utf8)
        try settings.write(to: dataURL.appendingPathComponent("settings.json"))
        try Data("hidden".utf8).write(to: dataURL.appendingPathComponent(".hidden"))
        try Data("disk image".utf8).write(to: dataURL.appendingPathComponent("smol/disk.raw"))
        try Data("keep".utf8).write(to: previous.appendingPathComponent("saved"))
        try Data("project".utf8).write(to: external.appendingPathComponent("compose.yaml"))
        try fm.createSymbolicLink(at: dataURL.appendingPathComponent("stacks"), withDestinationURL: external)

        let archive = try ApplicationMaintenance.archiveData(at: dataURL)

        #expect(archive.deletingLastPathComponent() == dataURL.appendingPathComponent("archive", isDirectory: true))
        #expect(archive.lastPathComponent.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{3}/) != nil)
        #expect(try fm.contentsOfDirectory(atPath: dataURL.path) == ["archive"])
        #expect(try Data(contentsOf: archive.appendingPathComponent("settings.json")) == settings)
        #expect(try Data(contentsOf: archive.appendingPathComponent(".hidden")) == Data("hidden".utf8))
        #expect(try Data(contentsOf: archive.appendingPathComponent("smol/disk.raw")) == Data("disk image".utf8))
        #expect(fm.fileExists(atPath: archive.appendingPathComponent("profiles/default").path))
        #expect(try Data(contentsOf: previous.appendingPathComponent("saved")) == Data("keep".utf8))
        #expect(try fm.destinationOfSymbolicLink(atPath: archive.appendingPathComponent("stacks").path) == external.path)
        #expect(try Data(contentsOf: external.appendingPathComponent("compose.yaml")) == Data("project".utf8))
    }

    @Test func repeatedUninstallsAtTheSameTimestampNeverOverwriteArchives() throws {
        let fm = FileManager.default
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = root.appendingPathComponent("settings.json")
        try Data("first".utf8).write(to: settings)
        let first = try ApplicationMaintenance.archiveData(at: root, now: date)
        try Data("second".utf8).write(to: settings)
        let second = try ApplicationMaintenance.archiveData(at: root, now: date)
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("settings.json")) == Data("first".utf8))
        #expect(try Data(contentsOf: second.appendingPathComponent("settings.json")) == Data("second".utf8))
    }

    @Test func failedArchivalRestoresMovedEntries() throws {
        let fm = FileManager.default
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.archiveData(at: root) { name in
                if name == "b" { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        for name in ["a", "b"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(name.utf8))
        }
        #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("archive").path).isEmpty)
    }

    @Test func refusesAnArchiveSymlink() throws {
        let fm = FileManager.default
        let root = try fixture()
        defer { try? fm.removeItem(at: root) }
        let dataURL = root.appendingPathComponent("data")
        let external = root.appendingPathComponent("external")
        try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("settings".utf8).write(to: dataURL.appendingPathComponent("settings.json"))
        try fm.createSymbolicLink(at: dataURL.appendingPathComponent("archive"), withDestinationURL: external)
        #expect(throws: (any Error).self) { try ApplicationMaintenance.archiveData(at: dataURL) }
        #expect(fm.fileExists(atPath: dataURL.appendingPathComponent("settings.json").path))
        #expect(try fm.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test @MainActor func refusesToUninstallAnUnbundledDevelopmentExecutable() {
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.validateAppBundle(URL(fileURLWithPath: "/workspace/.build/debug/macos"))
        }
    }

    private static let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let helperExecutable: Result<URL, Error> = Result {
        let directory = packageURL.appendingPathComponent(".build/maintenance-fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("maintenance-helper")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-swift-version", "6", "-D", "MAINTENANCE_FIXTURE",
            "-module-cache-path", directory.appendingPathComponent("module-cache").path,
            packageURL.appendingPathComponent("Sources/macos/LauncherLifecycle.swift").path,
            packageURL.appendingPathComponent("Sources/macos/ApplicationMaintenance.swift").path,
            packageURL.appendingPathComponent("Sources/macos/MaintenanceFileOperations.swift").path,
            packageURL.appendingPathComponent("Tests/Fixtures/MaintenanceHelper/main.swift").path,
            "-o", executable.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MaintenanceFailure("Fixture compilation failed: " + String(decoding: diagnostics, as: UTF8.self))
        }
        return executable
    }

    private func helperFixture() throws -> URL {
        let root = try fixture()
        let fm = FileManager.default
        let app = root.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("data/profiles"), withIntermediateDirectories: true)
        try Data("original settings".utf8).write(to: root.appendingPathComponent("data/settings.json"))
        try fm.copyItem(at: Self.helperExecutable.get(), to: app.appendingPathComponent("MacOS/fixture"))
        let info: [String: Any] = ["CFBundleName": "Maintenance Fixture", "CFBundleExecutable": "fixture",
            "CFBundleIdentifier": "dev.xe.maintenance-fixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        return root
    }

    private func runHost(_ mode: String, root: URL) throws {
        let host = Process()
        host.executableURL = try Self.helperExecutable.get()
        host.arguments = ["host", root.path, mode]
        try ApplicationMaintenance.runBounded(host, timeout: 10)
    }

    private func awaitFile(_ name: String, root: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("failed").path) {
                throw MaintenanceFailure(try String(contentsOf: root.appendingPathComponent("failed"), encoding: .utf8))
            }
            guard ContinuousClock.now < deadline else { throw MaintenanceFailure("Fixture did not produce \(name).") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func helperCompletesUninstallOnlyAfterCommitAndParentExit() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Process()
        let input = Pipe()
        let output = Pipe()
        host.executableURL = try Self.helperExecutable.get()
        host.arguments = ["host", root.path, "hold"]
        host.standardInput = input
        host.standardOutput = output
        try host.run()
        defer { if host.isRunning { host.terminate() } }
        // This acknowledgment proves both helper readiness and commit handling;
        // there is no scheduler-dependent sleep before testing the exit gate.
        let acknowledgment = try output.fileHandleForReading.read(upToCount: 10)
        try #require(acknowledgment == Data("committed\n".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archived").path))
        #expect(throws: (any Error).self) { try LauncherLifecycle(directoryURL: root.appendingPathComponent("lifecycle")) }
        try input.fileHandleForWriting.close()
        host.waitUntilExit()
        try await awaitFile("completed", root: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Fixture.app").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path).count == 1)
        let archive = try String(contentsOf: root.appendingPathComponent("archived"), encoding: .utf8)
        #expect(try String(contentsOfFile: archive + "/settings.json", encoding: .utf8) == "original settings")
    }

    @Test(arguments: ["containerVM-failure", "browserStack-failure", "hostServices-failure", "no-commit", "parent-crash", "invalid-commit"])
    func helperNeverArchivesOnFailedOrMissingAuthorization(_ mode: String) async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runHost(mode, root: root)
        // Reacquisition synchronizes with helper exit, not an arbitrary delay.
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? LauncherLifecycle(directoryURL: root.appendingPathComponent("lifecycle"))) == nil {
            guard ContinuousClock.now < deadline else { throw MaintenanceFailure("Cancelled helper retained its lock.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/settings.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Fixture.app").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archived").path))
    }

    @Test func helperRetainsLifecycleLockThroughoutArchival() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runHost("hold-operation", root: root)
        try await awaitFile("operation-entered", root: root)
        #expect(throws: (any Error).self) { try LauncherLifecycle(directoryURL: root.appendingPathComponent("lifecycle")) }
        try Data().write(to: root.appendingPathComponent("release"))
        try await awaitFile("completed", root: root)
    }

    @Test func helperRelaunchesAnActualFixtureBundle() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runHost("restart", root: root)
        try await awaitFile("relaunched", root: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archived").path))
    }

    @Test func trashFailureLeavesApprovedBundleAndArchivedData() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runHost("trash-failure", root: root)
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("failed").path) {
            guard ContinuousClock.now < deadline else { throw MaintenanceFailure("Trash failure was not reported.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Fixture.app").path))
        let archive = try String(contentsOf: root.appendingPathComponent("archived"), encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: archive + "/settings.json"))
    }

    @Test(arguments: ["startup-failure", "unresponsive-startup", "wrong-nonce"])
    func helperMustAcknowledgeReadiness(_ mode: String) throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try runHost(mode, root: root) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/settings.json").path))
    }

    @Test(arguments: [["--xe-uninstall-after-exit", "2", "nonce"], ["--xe-uninstall-after-exit"], ["--xe-restart-after-exit", "garbage"]])
    func actualLauncherRejectsDirectOrMalformedHelperInvocations(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = Self.packageURL.appendingPathComponent(".build/debug/macos")
        process.arguments = arguments
        #expect(throws: (any Error).self) { try ApplicationMaintenance.runBounded(process, timeout: 3) }
        #expect(process.terminationStatus == 1)
    }

    @Test func evenTheCorrectParentPIDCannotReplaceAnAuthorizedChannel() throws {
        let process = Process()
        process.executableURL = Self.packageURL.appendingPathComponent(".build/debug/macos")
        process.arguments = ["--xe-uninstall-after-exit", String(ProcessInfo.processInfo.processIdentifier), UUID().uuidString]
        #expect(throws: (any Error).self) { try ApplicationMaintenance.runBounded(process, timeout: 3) }
        #expect(process.terminationStatus == 1)
    }

    @Test func privateBrowserHelpersAreIncludedWithoutMatchingUnrelatedEngines() {
        let data = URL(fileURLWithPath: "/Users/test/Library/Application Support/dev.xe.computer")
        #expect(ExternalState.isPrivateBrowserExecutable(data.path + "/helium/1/Helium.app/Contents/Frameworks/Helium Helper (Renderer).app/Contents/MacOS/Helium Helper (Renderer)", dataURL: data))
        #expect(ExternalState.isPrivateBrowserExecutable(data.path + "/Helium.app/Contents/MacOS/Helium", dataURL: data))
        #expect(!ExternalState.isPrivateBrowserExecutable(data.path + "-other/helium/1/Helium", dataURL: data))
        #expect(!ExternalState.isPrivateBrowserExecutable("/Applications/Helium.app/Contents/MacOS/Helium", dataURL: data))
    }

    @Test func relaunchCommandHasABoundedTimeout() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        let start = ContinuousClock.now
        #expect(throws: (any Error).self) { try ApplicationMaintenance.runBounded(process, timeout: 0.05) }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func rejectsRedirectedRootsAndAncestors() throws {
        let root = try fixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try fm.createDirectory(at: external.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: external.appendingPathComponent("data/settings.json"))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: external)
        #expect(throws: (any Error).self) { try ApplicationMaintenance.archiveData(at: link.appendingPathComponent("data")) }
        #expect(throws: (any Error).self) { try ApplicationMaintenance.archiveData(at: link) }
        #expect(try fm.contentsOfDirectory(atPath: external.appendingPathComponent("data").path) == ["settings.json"])
    }

    @Test func rootReplacementDuringArchivalRestoresOriginalAndNeverTouchesReplacement() throws {
        let root = try fixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        let original = root.appendingPathComponent("original")
        let external = root.appendingPathComponent("external")
        for directory in [data, external] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        for name in ["a", "b"] { try Data(name.utf8).write(to: data.appendingPathComponent(name)) }
        try Data("keep".utf8).write(to: external.appendingPathComponent("unrelated"))
        let pinned = try AnchoredDirectory(data)
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.archiveData(in: pinned) { name in
                if name == "b" {
                    try fm.moveItem(at: data, to: original)
                    try fm.createSymbolicLink(at: data, withDestinationURL: external)
                }
            }
        }
        for name in ["a", "b"] { #expect(try Data(contentsOf: original.appendingPathComponent(name)) == Data(name.utf8)) }
        #expect(try fm.contentsOfDirectory(atPath: external.path) == ["unrelated"])
    }

    @Test func replacedApprovedBundleIsRestoredBeforeAnythingEntersTrash() throws {
        let root = try helperFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let saved = root.appendingPathComponent("Approved.app")
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/fixture"))
        let trash = root.appendingPathComponent("Trash")
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.trashApprovedBundle(bundle, trashURL: trash) {
                try fm.moveItem(at: app, to: saved)
                try fm.createDirectory(at: app, withIntermediateDirectories: true)
                try Data("unrelated".utf8).write(to: app.appendingPathComponent("keep"))
            }
        }
        #expect(fm.fileExists(atPath: saved.appendingPathComponent("Contents/MacOS/fixture").path))
        #expect(try Data(contentsOf: app.appendingPathComponent("keep")) == Data("unrelated".utf8))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
    }

    @Test func replacedBundleContentsArePreservedAndUninstallFails() throws {
        let root = try helperFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/fixture"))
        let trash = root.appendingPathComponent("Trash")
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.trashApprovedBundle(bundle, trashURL: trash) {
                try fm.moveItem(at: app.appendingPathComponent("Contents/Info.plist"), to: root.appendingPathComponent("original-info"))
                try Data("replacement".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
        }
        #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == Data("replacement".utf8))
        #expect(try fm.contentsOfDirectory(atPath: trash.path).isEmpty)
    }
}
