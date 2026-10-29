import Foundation
import Synchronization
import Testing
@testable import macos

struct ApplicationMaintenanceTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xe-maintenance-\(UUID())", isDirectory: true)
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
            try ApplicationMaintenance.archiveData(at: root) { source, destination in
                if source.lastPathComponent == "b" { throw CocoaError(.fileWriteNoPermission) }
                try fm.moveItem(at: source, to: destination)
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

    @Test func waitsForProcessExitAndRefusesToProceedOnTimeout() async throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.waitForExit(of: process.processIdentifier, timeout: 0)
        }
        let finished = Mutex(false)
        let pid = process.processIdentifier
        let waiter = Task.detached {
            try ApplicationMaintenance.waitForExit(of: pid)
            finished.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.withLock { $0 })
        try input.fileHandleForWriting.close()
        try await waiter.value
        #expect(finished.withLock { $0 })
        process.waitUntilExit()
        // Registration also handles a process that has already exited.
        try ApplicationMaintenance.waitForExit(of: pid)
    }

    @Test @MainActor func refusesToUninstallAnUnbundledDevelopmentExecutable() {
        #expect(throws: (any Error).self) {
            try ApplicationMaintenance.validateAppBundle(URL(fileURLWithPath: "/workspace/.build/debug/macos"))
        }
    }
}
