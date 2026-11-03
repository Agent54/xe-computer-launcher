import Foundation
import Testing
@testable import macos

struct SystemLogStoreTests {
    private func directory() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/system-log-tests/\(UUID().uuidString)")
    }

    @Test func revisionChangesWhenTheRecentBufferIsFull() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory, configuration: .init(memoryEntries: 3))
        for line in 1...3 { store.append("launcher", "line \(line)") }
        let before = store.snapshot()
        store.append("docker", "startup failed")
        let after = store.snapshot()
        #expect(before.entries.count == after.entries.count)
        #expect(before.revision != after.revision)
        #expect(after.entries.map(\.line) == ["line 2", "line 3", "startup failed"])
        await store.flush()
    }

    @Test func historySurvivesRestartAndCanBePagedBySource() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory, configuration: .init(memoryEntries: 3))
        for line in 1...12 { store.append(line.isMultiple(of: 2) ? "docker" : "browser", "line \(line)") }
        await store.flush()
        let reopened = SystemLogStore(directoryURL: directory)
        reopened.append("docker", "new launch")
        let recent = await reopened.history(limit: 3, sources: ["docker"])
        #expect(recent.entries.map(\.line) == ["line 10", "line 12", "new launch"])
        #expect(recent.hasEarlier)
        let earlier = await reopened.history(before: recent.entries.first?.id, limit: 10, sources: ["docker"])
        #expect(earlier.entries.map(\.line) == ["line 2", "line 4", "line 6", "line 8"])
        #expect(!earlier.hasEarlier)
    }

    @Test func rotationBoundsDiskHistoryWithoutLosingTheNewestEntries() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SystemLogStore.Configuration(memoryEntries: 3, fileBytes: 512, fileCount: 3)
        let store = SystemLogStore(directoryURL: directory, configuration: configuration)
        for line in 1...40 { store.append("docker", "entry \(line): " + String(repeating: "x", count: 80)) }
        let history = await store.history(limit: 100)
        #expect(history.entries.count < 40)
        #expect(history.entries.last?.line.hasPrefix("entry 40:") == true)
        #expect(history.entries.map(\.id) == history.entries.map(\.id).sorted())
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 3)
        for file in files {
            #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 512)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func concurrentProducersKeepUniqueOrderedRecords() async {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory)
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask { for line in 0..<100 { store.append("compose", "\(producer):\(line)") } }
            }
        }
        let history = await store.history()
        #expect(history.entries.count == 800)
        #expect(Set(history.entries.map(\.id)).count == 800)
        #expect(Set(history.entries.map(\.line)).count == 800)
        #expect(history.entries.map(\.id) == history.entries.map(\.id).sorted())
    }

    @Test func partialLastRecordDoesNotHideLogsFromTheNextLaunch() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory)
        store.append("docker", "previous startup error")
        await store.flush()
        let file = try FileHandle(forWritingTo: directory.appendingPathComponent("system.jsonl"))
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"id\":999".utf8))
        try file.close()
        let reopened = SystemLogStore(directoryURL: directory)
        reopened.append("launcher", "new launch")
        #expect(await reopened.history().entries.map(\.line) == ["previous startup error", "new launch"])
    }

    @Test func diskWriteFailureIsVisibleAndMemoryLoggingContinues() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let store = SystemLogStore(directoryURL: blocked)
        store.append("docker", "original failure")
        await store.flush()
        store.append("launcher", "still running")
        await store.flush()
        let lines = store.snapshot().entries.map(\.line)
        #expect(lines.first == "original failure")
        #expect(lines.last == "still running")
        #expect(lines.filter { $0.hasPrefix("Could not save System Logs:") }.count == 1)
        #expect(store.latestIssue?.severity == .error)
    }

    @Test func shutdownWarningSurvivesRelaunchAndLogRotation() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory,
            configuration: .init(memoryEntries: 2, fileBytes: 512, fileCount: 2))
        store.append("launcher", "Chrome process group did not exit after Browser.close (10.0s); sending SIGTERM")
        let warning = try #require(store.latestIssue)
        for index in 0..<30 { store.append("launcher", "normal line \(index): " + String(repeating: "x", count: 120)) }
        await store.flush()
        #expect(!store.snapshot().entries.contains(warning))
        #expect(!(await store.history()).entries.contains(warning))
        let reopened = SystemLogStore(directoryURL: directory)
        #expect(reopened.latestIssue == warning)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("last-warning.json").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func repeatedErrorsShareAnIssueButNewErrorsAndRecurrencesWarnAgain() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemLogStore(directoryURL: directory)
        store.append("browser", "Process exited with code -1")
        let first = try #require(store.latestIssue)
        store.append("launcher", "normal progress")
        store.append("browser", "Process exited with code -1")
        #expect(store.latestIssue == first)
        store.append("workerd", "Error: connection failed")
        #expect(store.latestIssue?.id != first.id)
        await store.flush()
        let reopened = SystemLogStore(directoryURL: directory)
        let previous = try #require(reopened.latestIssue)
        reopened.append(previous.source, previous.line)
        #expect(try #require(reopened.latestIssue).id > previous.id)
        await reopened.flush()
    }

    @Test func importsAnOldBrowserCrashWithoutReplayingHealthyShutdownLogs() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let crash = SystemLogStore.Entry(id: 41, source: "launcher", line: "browser process exited (code=-1)", timestamp: Date())
        let healthy = SystemLogStore.Entry(id: 42, source: "launcher", line: "Shutdown complete in 0.6s", timestamp: Date())
        var data = try JSONEncoder().encode(crash)
        data.append(0x0a)
        data.append(try JSONEncoder().encode(healthy))
        data.append(0x0a)
        try data.write(to: directory.appendingPathComponent("system.jsonl"))
        let reopened = SystemLogStore(directoryURL: directory)
        await reopened.flush()
        #expect(reopened.latestIssue == crash)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("last-warning.json").path))
    }
}
