import Foundation
import Testing
import LauncherMaintenance
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
            try ApplicationMaintenance.validateAppBundle(URL(fileURLWithPath: "/workspace/unbundled-launcher"))
        }
    }

    // Resolve siblings of this test bundle, so debug and release tests always
    // exercise the products SwiftPM just built for that configuration.
    private static let productsURL = TestProducts.directory
    private static let helperExecutable = TestProducts.executable("maintenance-test-helper")

    private func helperFixture() throws -> URL {
        let root = try fixture()
        let fm = FileManager.default
        let app = root.appendingPathComponent("Fixture.app/Contents")
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("data/profiles"), withIntermediateDirectories: true)
        try Data("original settings".utf8).write(to: root.appendingPathComponent("data/settings.json"))
        try fm.copyItem(at: Self.helperExecutable, to: app.appendingPathComponent("MacOS/fixture"))
        let info: [String: Any] = ["CFBundleName": "Maintenance Fixture", "CFBundleExecutable": "fixture",
            "CFBundleIdentifier": "dev.xe.maintenance-fixture.\(UUID().uuidString)", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        return root
    }

    private func runHost(_ mode: String, root: URL) throws {
        let host = Process()
        host.executableURL = Self.helperExecutable
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
        host.executableURL = Self.helperExecutable
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
        process.executableURL = Self.productsURL.appendingPathComponent("macos")
        process.arguments = arguments
        #expect(throws: (any Error).self) { try ApplicationMaintenance.runBounded(process, timeout: 3) }
        #expect(process.terminationStatus == 1)
    }

    @Test func evenTheCorrectParentPIDCannotReplaceAnAuthorizedChannel() throws {
        let fm = FileManager.default
        // Keep the bundle on a literal path: Foundation rewrites /private/tmp
        // to the /tmp symlink, which the identity walk deliberately rejects.
        let root = Self.productsURL.appendingPathComponent("launcher-channel-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let contents = root.appendingPathComponent("Launcher.app/Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        let executable = contents.appendingPathComponent("MacOS/macos")
        try fm.copyItem(at: Self.productsURL.appendingPathComponent("macos"), to: executable)
        try fm.copyItem(at: Self.productsURL.appendingPathComponent("Sparkle.framework"),
                        to: contents.appendingPathComponent("Frameworks/Sparkle.framework"))
        let info = ["CFBundleIdentifier": "dev.xe.maintenance-channel-test", "CFBundleExecutable": "macos", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["--xe-uninstall-after-exit", String(ProcessInfo.processInfo.processIdentifier), UUID().uuidString]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        #expect(throws: (any Error).self) { try ApplicationMaintenance.runBounded(process, timeout: 3) }
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 1)
        #expect(String(decoding: diagnostic, as: UTF8.self).contains("Maintenance requires an inherited control socket."))
        #expect(fm.fileExists(atPath: executable.path))
    }

    @Test func asyncSettingsTerminationUsesTheBuiltFixture() throws {
        let process = Process()
        process.executableURL = Self.productsURL.appendingPathComponent("settings-termination-test")
        try ApplicationMaintenance.runBounded(process, timeout: 10)
    }

    @Test @MainActor func readinessWaitLeavesTheMainActorResponsiveAndCanBeCancelled() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = try LauncherLifecycle(directoryURL: root.appendingPathComponent("lifecycle"))
        let data = try AnchoredDirectory(root.appendingPathComponent("data"))
        let app = root.appendingPathComponent("Fixture.app")
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/fixture"))
        let request = ApplicationMaintenance.Request(action: .uninstall, nonce: UUID().uuidString, data: data.identity,
                                                     lifecycle: lifecycle.directory.identity, bundle: bundle)
        let helper = Process()
        helper.executableURL = Self.helperExecutable
        helper.arguments = ["worker", root.path, "unresponsive-startup", request.nonce, String(ProcessInfo.processInfo.processIdentifier)]
        let start = ContinuousClock.now
        let preparation = Task { try await ApplicationMaintenance.startHelper(helper, request: request, lifecycle: lifecycle) }
        try await awaitFile("startup-entered", root: root)
        #expect(ContinuousClock.now - start < .seconds(2))
        preparation.cancel()
        await #expect(throws: (any Error).self) { try await preparation.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archived").path))
    }

    @Test @MainActor func commitWaitLeavesTheMainActorResponsiveAndCanBeCancelled() async throws {
        let root = try helperFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = try LauncherLifecycle(directoryURL: root.appendingPathComponent("lifecycle"))
        let data = try AnchoredDirectory(root.appendingPathComponent("data"))
        let app = root.appendingPathComponent("Fixture.app")
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/fixture"))
        let request = ApplicationMaintenance.Request(action: .uninstall, nonce: UUID().uuidString, data: data.identity,
                                                     lifecycle: lifecycle.directory.identity, bundle: bundle)
        let helper = Process()
        helper.executableURL = Self.helperExecutable
        helper.arguments = ["worker", root.path, "hold", request.nonce, String(ProcessInfo.processInfo.processIdentifier)]
        let handoff = try await ApplicationMaintenance.startHelper(helper, request: request, lifecycle: lifecycle)
        // Readiness is acknowledged before stopping the peer, so commit cannot
        // receive an acknowledgment until we explicitly resume it.
        try #require(kill(helper.processIdentifier, SIGSTOP) == 0)
        defer { handoff.cancel(); kill(helper.processIdentifier, SIGCONT) }
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let start = ContinuousClock.now
        let commit = Task {
            entry.yield(())
            try await handoff.authorize(ShutdownResult(stopped: Set(ShutdownResult.Component.allCases), failures: []))
        }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        try await Task.sleep(for: .milliseconds(50))
        #expect(ContinuousClock.now - start < .seconds(2))
        handoff.cancel()
        kill(helper.processIdentifier, SIGCONT)
        await #expect(throws: (any Error).self) { try await commit.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("archived").path))
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
