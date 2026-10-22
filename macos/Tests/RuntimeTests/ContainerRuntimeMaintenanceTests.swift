import Foundation
import Synchronization
import Testing
@testable import macos

struct ContainerRuntimeMaintenanceTests {
    private func workspaceStateURL() throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = workspace.appendingPathComponent(".build/maintenance-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }

    @Test func fourHourScheduleSurvivesRestartAndDoesNotRunOnEveryProbe() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let commands = Mutex<[[String]]>([])
        let logs = Mutex<[String]>([])
        let execute: ContainerRuntimeMaintenance.Execute = { command in
            commands.withLock { $0.append(command) }
            if command == VMResourceSampler.guestDiskStatusCommand {
                return SmolVMCommandResult(standardOutput: "4096 5242880 500000 1310720 631351", standardError: "", exitCode: 0)
            }
            return SmolVMCommandResult(
                standardOutput: command.contains("buildx")
                    ? "ID\tRECLAIMABLE\tSIZE\tLAST ACCESSED\nexample\ttrue\t10MB\t24 hours ago\nTotal:\t10MB\n"
                    : "Deleted Images:\nsha256:example\nTotal reclaimed space: 10MB\n",
                standardError: "", exitCode: 0
            )
        }
        let maintenance = ContainerRuntimeMaintenance(
            stateURL: stateURL, execute: execute, now: { clock.withLock { $0 } },
            log: { line in logs.withLock { $0.append(line) } }
        )
        let first = try #require(await maintenance.reconcile())
        await first.value
        #expect(commands.withLock { $0 } == [
            ["docker", "image", "prune", "--all", "--force", "--filter", "until=32h"],
            ["docker", "buildx", "prune", "--builder", "default", "--all", "--force",
             "--filter", "until=32h"],
            ["stat", "-f", "-c", "%S %b %a %c %d", "/storage/docker"],
        ])
        #expect(logs.withLock { $0.last } == "Build cache cleanup completed: Total:\t10MB")
        let completed = await maintenance.snapshot()
        #expect(!completed.running)
        #expect(completed.completedAt == clock.withLock { $0 })
        #expect(completed.results.map(\.reclaimedBytes) == [10_000_000, 10_000_000])
        #expect(completed.buildCacheMinimumFreeDiskPercent == 5)
        #expect(completed.buildCacheMinimumAgeHours == 32)
        #expect(completed.cachePressureWarning == nil)
        #expect(await maintenance.reconcile() == nil)

        let restarted = ContainerRuntimeMaintenance(
            stateURL: stateURL, execute: execute, now: { clock.withLock { $0 } }, log: { _ in }
        )
        clock.withLock { $0.addTimeInterval(4 * 60 * 60 - 1) }
        #expect(await restarted.reconcile() == nil)
        clock.withLock { $0.addTimeInterval(1) }
        let second = try #require(await restarted.reconcile())
        await second.value
        #expect(commands.withLock { $0.count } == 6)
        #expect(await restarted.reconcile() == nil)
    }

    @Test func failureWaitsForTheNextIntervalAndDoesNotBlockRuntimeHealth() async throws {
        struct CleanupFailure: Error {}
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let attempts = Mutex(0)
        let logs = Mutex<[String]>([])
        let maintenance = ContainerRuntimeMaintenance(
            stateURL: stateURL,
            execute: { _ in
                attempts.withLock { $0 += 1 }
                throw CleanupFailure()
            },
            now: { clock.withLock { $0 } },
            log: { line in logs.withLock { $0.append(line) } }
        )
        let first = try #require(await maintenance.reconcile())
        await first.value
        #expect(await maintenance.reconcile() == nil)
        #expect(attempts.withLock { $0 } == 2)
        #expect(logs.withLock { $0.last?.hasPrefix("Build cache cleanup failed:") } == true)
        clock.withLock { $0.addTimeInterval(4 * 60 * 60) }
        let retry = try #require(await maintenance.reconcile())
        await retry.value
        #expect(attempts.withLock { $0 } == 4)
    }

    @Test func lowDiskSamplesTriggerEarlyCleanupWithABoundedRetryRate() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            SmolVMCommandResult(standardOutput: command == VMResourceSampler.guestDiskStatusCommand
                ? "4096 5242880 500000 0 0" : "Total:\t0B", standardError: "", exitCode: 0)
        }, now: { clock.withLock { $0 } }, log: { _ in })
        let lowDisk = VMResourceSnapshot(memoryResidentBytes: nil, memoryLimitBytes: nil,
            diskAllocatedBytes: nil, diskLogicalBytes: nil, diskTotalBytes: 100,
            diskAvailableBytes: 4, diskTotalInodes: nil, diskFreeInodes: nil)
        let first = try #require(await maintenance.reconcile())
        await first.value
        clock.withLock { $0.addTimeInterval(59) }
        #expect(await maintenance.reconcile(resources: lowDisk) == nil)
        clock.withLock { $0.addTimeInterval(1) }
        #expect(await maintenance.reconcile() == nil)
        let pressureRun = try #require(await maintenance.reconcile(resources: lowDisk))
        await pressureRun.value
        #expect(await maintenance.reconcile(resources: lowDisk) == nil)
    }

    @Test func manualCleanupBypassesScheduleAndPersistsResults() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        // Records from the earlier image-only scheduler remain readable.
        try Data(#"{"lastImagePruneAttemptAt":"2027-01-15T08:00:00Z"}"#.utf8).write(to: stateURL)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let commands = Mutex<[[String]]>([])
        let execute: ContainerRuntimeMaintenance.Execute = { command in
            commands.withLock { $0.append(command) }
            if command == VMResourceSampler.guestDiskStatusCommand {
                return SmolVMCommandResult(standardOutput: "4096 5242880 500000 1310720 631351", standardError: "", exitCode: 0)
            }
            return SmolVMCommandResult(
                standardOutput: command.contains("buildx") ? "Total:\t1.25GB\n" : "Total reclaimed space: 1.25GB\n",
                standardError: "", exitCode: 0
            )
        }
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: execute, now: { clock }, log: { _ in })
        #expect(await maintenance.reconcile() == nil)
        let running = try #require(await maintenance.reconcile(force: true))
        await running.value
        #expect(commands.withLock { $0.count } == 3)
        let restored = ContainerRuntimeMaintenance(stateURL: stateURL, execute: execute, now: { clock }, log: { _ in })
        let snapshot = await restored.snapshot()
        #expect(snapshot.completedAt == clock)
        #expect(snapshot.results.map(\.reclaimedBytes) == [1_250_000_000, 1_250_000_000])
        #expect(snapshot.nextRunAt == clock.addingTimeInterval(4 * 60 * 60))
        #expect(await restored.reconcile() == nil)
    }

    @Test(arguments: [
        (1, 1), (20, 1), (21, 2),
        (21_474_836_480, 1_073_741_824), (42_949_672_960, 2_147_483_648),
        (UInt64.max, 922_337_203_685_477_581),
    ] as [(UInt64, UInt64)])
    func freeDiskTargetRoundsUpAndHandlesLargeDisks(capacity: UInt64, expected: UInt64) {
        #expect(ContainerRuntimeMaintenance.buildCacheMinimumFreeBytes(diskTotalBytes: capacity) == expected)
    }

    @Test func youngerCachePassesStopWhenCurrentFilesystemReachesFivePercentFree() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let freeBlocks = Mutex([40_000, 200_000, 262_144])
        let commands = Mutex<[[String]]>([])
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            commands.withLock { $0.append(command) }
            if command == VMResourceSampler.guestDiskStatusCommand {
                let available = freeBlocks.withLock { $0.removeFirst() }
                return SmolVMCommandResult(standardOutput: "4096 5242880 \(available) 0 0", standardError: "", exitCode: 0)
            }
            return SmolVMCommandResult(standardOutput: "Total:\t0B", standardError: "", exitCode: 0)
        }, log: { _ in })
        let first = try #require(await maintenance.reconcile())
        await first.value
        let cacheCommands = commands.withLock { $0.filter { $0.contains("buildx") } }
        #expect(cacheCommands.map(\.last) == ["until=32h", "until=8h", "until=1h"])
        let snapshot = await maintenance.snapshot()
        #expect(snapshot.results.allSatisfy { $0.error == nil })
        #expect(snapshot.cachePressureWarning?.message.contains("younger than 32 hours") == true)
    }

    @Test func pressureWarningIsPublishedBeforePruningAndSurvivesCancellationRelaunchAndNormalCleanup() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let started = AsyncStream<Void>.makeStream()
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            if command.last == "until=8h" {
                started.continuation.yield(())
                started.continuation.finish()
                try await Task.sleep(for: .seconds(30))
            }
            return SmolVMCommandResult(standardOutput: command == VMResourceSampler.guestDiskStatusCommand
                ? "4096 5242880 0 0 0" : "Total:\t0B", standardError: "", exitCode: 0)
        }, log: { _ in })
        let run = try #require(await maintenance.reconcile())
        for await _ in started.stream { break }
        let warning = try #require((await maintenance.snapshot()).cachePressureWarning)
        #expect(warning.message.contains("below 5%"))
        await maintenance.pause()
        await run.value
        let restored = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            SmolVMCommandResult(standardOutput: command == VMResourceSampler.guestDiskStatusCommand
                ? "4096 5242880 500000 0 0" : "Total:\t0B", standardError: "", exitCode: 0)
        }, log: { _ in })
        #expect((await restored.snapshot()).cachePressureWarning?.id == warning.id)
        let normalRun = try #require(await restored.reconcile(force: true))
        await normalRun.value
        #expect((await restored.snapshot()).cachePressureWarning?.id == warning.id)
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: stateURL.deletingLastPathComponent()),
            maintenance: restored, readHostResources: { nil }, readVMResources: { _ in nil },
            onStatusChanged: { _ in }, log: { _ in }
        )
        await supervisor.prepareForLaunch()
        #expect((await supervisor.snapshot()).cachePressureWarning?.id == warning.id)
    }

    @Test func freeDiskTargetUsesCurrentCapacityAfterResizeAndReportsUnreclaimablePressure() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let blocks = Mutex(5_242_880)
        let commands = Mutex<[[String]]>([])
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            commands.withLock { $0.append(command) }
            if command == VMResourceSampler.guestDiskStatusCommand {
                return SmolVMCommandResult(standardOutput: "4096 \(blocks.withLock { $0 }) 300000 0 0", standardError: "", exitCode: 0)
            }
            return SmolVMCommandResult(standardOutput: "Total:\t0B", standardError: "", exitCode: 0)
        }, log: { _ in })
        let first = try #require(await maintenance.reconcile())
        await first.value
        #expect(commands.withLock { $0.filter { $0.contains("buildx") }.count } == 1)
        commands.withLock { $0 = [] }
        blocks.withLock { $0 *= 2 }
        let resized = try #require(await maintenance.reconcile(force: true))
        await resized.value
        #expect(commands.withLock { $0.filter { $0.contains("buildx") }.map(\.last) }
                == ["until=32h", "until=8h", "until=1h", "until=0h"])
        let snapshot = await maintenance.snapshot()
        #expect(snapshot.results.last?.error?.hasPrefix("Less than 5% disk space remains") == true)
        #expect(Set(snapshot.results.map(\.name)).count == snapshot.results.count)
    }

    @Test(arguments: [
        ("invalid", 0), ("4096 0 0 0 0", 0),
        ("18446744073709551615 2 0 0 0", 0), ("4096 5242880 0 0 0", 1),
    ] as [(String, Int32)])
    func invalidFilesystemCapacityPreservesYoungerCache(output: String, exitCode: Int32) async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let commands = Mutex<[[String]]>([])
        let maintenance = ContainerRuntimeMaintenance(stateURL: stateURL, execute: { command in
            commands.withLock { $0.append(command) }
            return SmolVMCommandResult(
                standardOutput: command == VMResourceSampler.guestDiskStatusCommand ? output : "Total reclaimed space: 0B",
                standardError: "", exitCode: command == VMResourceSampler.guestDiskStatusCommand ? exitCode : 0
            )
        }, log: { _ in })
        let running = try #require(await maintenance.reconcile())
        await running.value
        #expect(commands.withLock { $0.filter { $0.contains("buildx") }.map(\.last) } == ["until=32h"])
        let snapshot = await maintenance.snapshot()
        #expect(snapshot.results.first?.reclaimedBytes == 0)
        #expect(snapshot.results.last?.error == "Could not read Docker filesystem capacity; skipped cleanup of younger cache.")
    }

    @Test(arguments: ["Total:\t0B", "Total reclaimed space: 0B", "  Total:\t0B\r\n"])
    func zeroReclaimedSpaceIsReported(output: String) {
        #expect(ContainerRuntimeMaintenance.reclaimedBytes(output) == 0)
    }

    @Test func unrecognizedReclaimedTotalsRemainUnavailable() {
        #expect(ContainerRuntimeMaintenance.reclaimedBytes("Total:\tunknown") == nil)
        #expect(ContainerRuntimeMaintenance.reclaimedBytes("Total:\t-1GB") == nil)
        #expect(ContainerRuntimeMaintenance.reclaimedBytes("Size:\t1GB") == nil)
    }

    @Test func cleanupDoesNotOverlapAndPausesBeforeVMShutdown() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = Mutex(false)
        let logs = Mutex<[String]>([])
        let maintenance = ContainerRuntimeMaintenance(
            stateURL: stateURL,
            execute: { _ in
                started.continuation.yield(())
                started.continuation.finish()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
                return SmolVMCommandResult(standardOutput: "", standardError: "", exitCode: 0)
            },
            log: { line in logs.withLock { $0.append(line) } }
        )
        let running = try #require(await maintenance.reconcile())
        for await _ in started.stream { break }
        #expect(await maintenance.reconcile() == nil)
        // A manual click joins the active run rather than starting another command.
        let joined = try #require(await maintenance.reconcile(force: true))
        await maintenance.pause()
        await running.value
        await joined.value
        #expect(cancelled.withLock { $0 })
        #expect(logs.withLock { $0.isEmpty })
        #expect(await maintenance.reconcile() == nil)
    }

    @Test func supervisorRunsCleanupOnlyWhileHealthyAndCancelsBeforeStoppingVM() async throws {
        let stateURL = try workspaceStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let started = AsyncStream<Void>.makeStream()
        let attempts = Mutex(0)
        let cancelled = Mutex(false)
        let stopped = Mutex(false)
        let probes = Mutex([false, true, true])
        let maintenance = ContainerRuntimeMaintenance(
            stateURL: stateURL,
            execute: { _ in
                attempts.withLock { $0 += 1 }
                started.continuation.yield(())
                started.continuation.finish()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
                return SmolVMCommandResult(standardOutput: "", standardError: "", exitCode: 0)
            },
            log: { _ in }
        )
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: stateURL.deletingLastPathComponent()),
            maintenance: maintenance,
            startMachine: {
                SmolVMStartupResult(machineName: "test", dockerSocketURL: stateURL)
            },
            stopMachine: {
                #expect(cancelled.withLock { $0 })
                stopped.withLock { $0 = true }
            },
            probeDocker: { probes.withLock { $0.removeFirst() } },
            readDiagnostics: { SmolVMMachine(name: "test", state: "running", labels: [:], memory: nil, workload: nil) },
            resetRouter: {}, reconcileRouter: {}, readHostResources: { nil }, readVMResources: { _ in nil },
            onStatusChanged: { _ in }, log: { _ in }
        )
        _ = try await supervisor.start()
        await supervisor.reconcile()
        #expect(attempts.withLock { $0 } == 0)
        await supervisor.reconcile()
        for await _ in started.stream { break }
        await supervisor.reconcile()
        #expect(attempts.withLock { $0 } == 1)
        try await supervisor.stop()
        #expect(stopped.withLock { $0 })
        #expect((await supervisor.snapshot()).phase == .stopped)
        await supervisor.reconcile()
        #expect(attempts.withLock { $0 } == 1)
    }
}
