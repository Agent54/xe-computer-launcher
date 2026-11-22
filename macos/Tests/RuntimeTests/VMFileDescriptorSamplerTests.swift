import Foundation
import Synchronization
import Testing
@testable import macos

struct VMFileDescriptorSamplerTests {
    private let containerID = String(repeating: "a", count: 64)

    @Test func parsesKernelHandlesSeparatelyFromProcessDescriptorsAndKeepsUnknownLimitsUnknown() {
        let sample = VMFileDescriptorSampler.parse("""
            VM\t100\t0\t1000
            PROCESS\t10\tweb\t99\t100\t200\t1\t0
            PROCESS\t20\tunlimited\t50\tunlimited\tunlimited\tunlimited\t0
            PROCESS\t30\tcapped\t131072\t1048576\t1048576\t917504\t1
            WATCH_LIMIT\t64379
            WATCHER_ERROR\t2026-10-25T10:21:50Z Inotify limit reached (ENOSPC)
            """, containerID: containerID, bootID: "boot", at: Date())
        #expect(sample.vm?.used == 100)
        #expect(sample.vm?.available == 900)
        #expect(sample.processes.first?.available == 1)
        #expect(sample.processes[1].softLimit == nil)
        #expect(sample.processes[1].available == nil)
        #expect(sample.processes[2].available == nil)
        #expect(sample.partial)
        #expect(sample.inotifyWatchLimit == 64_379)
        #expect(sample.watcherError?.contains("ENOSPC") == true)
        let invalid = VMFileDescriptorSampler.parse("VM\t-1\t0\t100\nERROR\n",
            containerID: containerID, bootID: "boot", at: Date())
        #expect(invalid.vm == nil)
        #expect(invalid.processError != nil)
        #expect(invalid.processes.isEmpty)
        #expect(invalid.watcherError == nil)
        #expect(invalid.inotifyWatchLimit == nil)
    }

    @Test func sharesConcurrentReadsForTenSecondsAndInvalidatesOnBootOrSelectionChange() async {
        let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let requests = Mutex<[[String]]>([])
        let sampler = VMFileDescriptorSampler(execute: { command in
            requests.withLock { $0.append(command) }
            try await Task.sleep(for: .milliseconds(5))
            return SmolVMCommandResult(standardOutput: "VM\t100\t0\t1000\n", standardError: "", exitCode: 0)
        }, now: { now.withLock { $0 } })
        async let first = sampler.sample(containerID: containerID, bootID: "boot-1")
        async let second = sampler.sample(containerID: containerID, bootID: "boot-1")
        let (firstResult, secondResult) = await (first, second)
        #expect(firstResult == secondResult)
        #expect(requests.withLock { $0.count } == 1)
        now.withLock { $0.addTimeInterval(9.9) }
        _ = await sampler.sample(containerID: containerID, bootID: "boot-1")
        #expect(requests.withLock { $0.count } == 1)
        now.withLock { $0.addTimeInterval(0.1) }
        _ = await sampler.sample(containerID: containerID, bootID: "boot-1")
        #expect(requests.withLock { $0.count } == 2)
        _ = await sampler.sample(containerID: containerID, bootID: "boot-2")
        #expect(requests.withLock { $0.count } == 3)
        _ = await sampler.sample(containerID: nil, bootID: "boot-2")
        #expect(requests.withLock { $0.last?[4] } == "")
        #expect(requests.withLock { $0.count } == 4)
    }

    @Test func failuresAndInvalidContainerIDsCannotCauseRepeatedOrArbitraryCommands() async {
        let calls = Mutex(0)
        let sampler = VMFileDescriptorSampler(execute: { _ in
            calls.withLock { $0 += 1 }
            throw CancellationError()
        })
        for id in ["", "short", "--privileged", "$(touch bad)", String(repeating: "g", count: 64)] {
            #expect(await sampler.sample(containerID: id, bootID: "boot") == nil)
        }
        #expect(calls.withLock { $0 } == 0)
        #expect(await sampler.sample(containerID: containerID, bootID: "boot") == nil)
        #expect(await sampler.sample(containerID: containerID, bootID: "boot") == nil)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func guestProbeOnlyReadsSelectedPIDsAndStreamsBoundedFDEntries() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/fd-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("proc/sys/fs/file-nr", "100 0 1000\n")
        try write("proc/sys/fs/inotify/max_user_watches", "64379\n")
        try write("bin/docker", """
            #!/bin/sh
            case "$1" in
              inspect) printf '2026-10-25T10:20:28Z\\n' ;;
              logs)
                [ "$2" = --since ] && [ "$3" = 2026-10-25T10:20:28Z ] || exit 1
                printf '2026-10-25T10:21:50Z [File Watcher] Inotify limit reached (ENOSPC)\\n'
                printf '2026-10-25T10:21:51Z unrelated disk ENOSPC\\n'
                printf '2026-10-25T10:21:52Z [File Watcher] Inotify limit reached (ENOSPC) /stacks/agents\\n'
                ;;
              top) printf 'PID\\n10\\n20\\n' ;;
            esac
            """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/docker").path)
        for pid in [10, 20, 99] {
            var fields = Array(repeating: "0", count: 20)
            fields[0] = "R"
            fields[19] = String(pid * 100)
            try write("proc/\(pid)/stat", "\(pid) (worker with spaces) \(fields.joined(separator: " "))\n")
            try write("proc/\(pid)/comm", "worker\t\(pid)\n")
            try write("proc/\(pid)/limits", "Max open files            4            16            files\n")
            for descriptor in [0, 1, 2, 7] { try write("proc/\(pid)/fd/\(descriptor)", "") }
        }
        let procRoot = root.appendingPathComponent("proc").path
        let path = "PATH=\(root.appendingPathComponent("bin").path):/usr/bin:/bin"
        func run(_ command: [String]) async throws -> FileDescriptorSnapshot {
            let result = try await Task.detached {
                try ProcessCapture.standardOutput(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [path] + command)
            }.value
            #expect(result.exitCode == 0)
            return VMFileDescriptorSampler.parse(String(decoding: result.standardOutput, as: UTF8.self),
                containerID: containerID, bootID: "boot", at: Date())
        }
        let sample = try await run(VMFileDescriptorSampler.command(containerID: containerID, procRoot: procRoot))
        #expect(sample.vm?.available == 900)
        #expect(sample.inotifyWatchLimit == 64_379)
        #expect(sample.watcherError == "2026-10-25T10:21:52Z [File Watcher] Inotify limit reached (ENOSPC) /stacks/agents")
        #expect(sample.processes.map(\.pid) == [10, 20])
        #expect(sample.processes.first?.used == 4)
        // FD 7 remains open above the lowered soft limit; only slots 0,1,2 are occupied below 4.
        #expect(sample.processes.first?.available == 1)
        #expect(!sample.partial)
        var capped = VMFileDescriptorSampler.command(containerID: containerID, procRoot: procRoot)
        capped[5] = "1"
        capped[6] = "3"
        let partial = try await run(capped)
        #expect(partial.partial)
        #expect(partial.processes.count == 1)
        #expect(partial.processes.first?.truncated == true)
        #expect(partial.processes.first?.available == nil)
        let global = try await run(VMFileDescriptorSampler.command(containerID: nil, procRoot: procRoot))
        #expect(global.vm?.available == 900)
        #expect(global.watcherError == nil)
        #expect(global.processes.isEmpty)
    }
}
