import Foundation
import Synchronization
import Testing
@testable import macos

struct RuntimeLogCollectorTests {
    private func directory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-log-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func capturesDockerStartupFailureAndOnlyReadsNewLines() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-console.log")
        let lines = Mutex<[(String, String)]>([])
        let collector = RuntimeLogCollector(directoryURL: directory, log: { source, line in lines.withLock { $0.append((source, line)) } })
        await collector.beginAttempt()
        try Data("{\"level\":\"INFO\",\"message\":\"boot\"}\ntime=\"now\" level=info msg=\"Starting up\"\n".utf8).write(to: file)
        await collector.collect()
        await collector.collect()
        #expect(lines.withLock { $0.count } == 2)
        let failure = "error initializing buildkit: failed to parse defaultMINFREESPACE: invalid suffix: %"
        try append(failure, to: file)
        await collector.collect()
        #expect(lines.withLock { $0.count } == 2)
        await collector.collect(flushPartial: true)
        #expect(lines.withLock { $0.last?.0 } == "docker")
        #expect(await collector.failureDetail() == failure)
        #expect(SmolVMSetupError.dockerStartupFailed(failure).localizedDescription.contains("invalid suffix"))
    }

    @Test func rotationAndRestartDoNotHideNewBootErrors() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-console.log")
        let lines = Mutex<[String]>([])
        let collector = RuntimeLogCollector(directoryURL: directory, log: { _, line in lines.withLock { $0.append(line) } })
        await collector.beginAttempt()
        try Data("first boot, with a longer console line\n".utf8).write(to: file)
        await collector.collect()
        try Data("second\n".utf8).write(to: file)
        await collector.collect()
        try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("1"))
        try Data("failed to start daemon: invalid configuration\n".utf8).write(to: file)
        await collector.collect()
        #expect(lines.withLock { $0 } == ["first boot, with a longer console line", "second", "failed to start daemon: invalid configuration"])
        #expect(await collector.failureDetail() != nil)
        await collector.beginAttempt()
        #expect(await collector.failureDetail() == nil)
    }

    @Test func hostProcessStartupErrorsAreIncludedAndMissingFilesAreHarmless() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = Mutex<[(String, String)]>([])
        let collector = RuntimeLogCollector(directoryURL: directory, log: { source, line in lines.withLock { $0.append((source, line)) } })
        await collector.beginAttempt()
        await collector.collect()
        try Data("VM failed to initialize\n".utf8).write(to: directory.appendingPathComponent("agent-startup-error.log"))
        await collector.collect()
        #expect(lines.withLock { $0.first?.0 } == "smolvm")
        #expect(lines.withLock { $0.first?.1 } == "VM failed to initialize")
    }

    @Test func attachingToARunningVMOnlyImportsNewOutput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-console.log")
        try Data("old output\n".utf8).write(to: file)
        let lines = Mutex<[String]>([])
        let collector = RuntimeLogCollector(directoryURL: directory, log: { _, line in lines.withLock { $0.append(line) } })
        await collector.collect()
        try append("new output\n", to: file)
        await collector.collect()
        await collector.collect()
        #expect(lines.withLock { $0 } == ["new output"])
    }

    @Test func newBootSkipsOldErrorsAndDetectsCopyTruncateEvenAfterTheFileRefills() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent-console.log")
        try Data("failed to start daemon: old error\n".utf8).write(to: file)
        let lines = Mutex<[String]>([])
        let collector = RuntimeLogCollector(directoryURL: directory, log: { _, line in lines.withLock { $0.append(line) } })
        await collector.beginAttempt()
        await collector.collect()
        #expect(lines.withLock { $0.isEmpty })
        #expect(await collector.failureDetail() == nil)
        let newError = "failed to start daemon: a different and longer error from this boot"
        try Data("new boot\n\(newError)\n".utf8).write(to: file)
        await collector.collect()
        await collector.collect()
        #expect(lines.withLock { $0 } == ["new boot", newError])
        #expect(await collector.failureDetail() == newError)
        await collector.beginAttempt()
        await collector.collect()
        #expect(await collector.failureDetail() == nil)
        #expect(lines.withLock { $0.count } == 2)
    }
}
