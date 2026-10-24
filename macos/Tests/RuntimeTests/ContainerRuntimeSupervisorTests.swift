import Foundation
import Synchronization
import Testing
@testable import macos

private actor RuntimeFixture {
    private var probes: [Bool]
    private var diagnostics: [SmolVMMachine]
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var routerResets = 0
    private(set) var routerReconciles = 0

    init(probes: [Bool], diagnostics: [SmolVMMachine]) {
        self.probes = probes
        self.diagnostics = diagnostics
    }

    func start() -> SmolVMStartupResult {
        starts += 1
        return SmolVMStartupResult(machineName: "test", dockerSocketURL: URL(fileURLWithPath: "/tmp/test.sock"))
    }

    func stop() { stops += 1 }
    func probe() -> Bool { probes.isEmpty ? true : probes.removeFirst() }
    func diagnostic() -> SmolVMMachine {
        diagnostics.count == 1 ? diagnostics[0] : diagnostics.removeFirst()
    }
    func resetRouter() { routerResets += 1 }
    func reconcileRouter() { routerReconciles += 1 }
}

@Suite(.serialized)
struct ContainerRuntimeSupervisorTests {
    private func machine(oomKillCount: UInt64, workloadOOM: Bool = false, workloadExited: Bool = false,
                         pid: Int32 = 123, memoryMiB: UInt64 = 4096) -> SmolVMMachine {
        SmolVMMachine(
            name: "test",
            state: "running",
            labels: [:],
            memory: SmolVMMemoryStatus(
                totalBytes: memoryMiB * 1_048_576,
                availableBytes: 2 * 1024 * 1024 * 1024,
                freeBytes: 1024,
                buffersBytes: 1024,
                cachedBytes: 1024,
                oomKillCount: oomKillCount
            ),
            workload: SmolVMWorkloadStatus(
                state: workloadOOM || workloadExited ? "exited" : "running",
                lastExitCode: workloadOOM ? 137 : nil,
                lastExitReason: workloadOOM ? "oom_killed" : nil,
                oomKilled: workloadOOM
            ),
            pid: pid, memoryMiB: memoryMiB
        )
    }

    @Test func oomRestartsTheWholeRuntimeAndPublishesCause() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(
            probes: [false, false, false],
            diagnostics: [machine(oomKillCount: 0)]
                + Array(repeating: machine(oomKillCount: 1, workloadOOM: true), count: 3)
                + [machine(oomKillCount: 0)]
        )
        let supervisor = ContainerRuntimeSupervisor(
            configuration: .init(
                failureThreshold: 3,
                maximumRecoveries: 3,
                recoveryWindow: 600,
                diagnosticInterval: 60,
                recoveryBackoff: .zero
            ),
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: {
                HostResourceSnapshot(
                    cpuPercent: 12.5,
                    cpuCount: 10,
                    memoryUsedBytes: 8 * 1024 * 1024 * 1024,
                    memoryTotalBytes: 16 * 1024 * 1024 * 1024,
                    diskUsedBytes: 100 * 1024 * 1024 * 1024,
                    diskTotalBytes: 500 * 1024 * 1024 * 1024
                )
            },
            readVMResources: { machine in
                guard machine != nil else { return nil }
                return VMResourceSnapshot(
                    memoryResidentBytes: 1024 * 1024,
                    memoryLimitBytes: 8192 * 1024 * 1024,
                    diskAllocatedBytes: 1024 * 1024,
                    diskLogicalBytes: 30 * 1024 * 1024 * 1024,
                    diskTotalBytes: 20 * 1024 * 1024 * 1024,
                    diskAvailableBytes: 0,
                    diskTotalInodes: 1_310_720,
                    diskFreeInodes: 631_409
                )
            },
            sleep: { _ in },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        _ = try await supervisor.start()
        let initialBootId = try #require((await supervisor.snapshot()).bootId)
        await supervisor.reconcile()
        await supervisor.reconcile()
        await supervisor.reconcile()

        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.reason == "oom_recovered")
        #expect(snapshot.lastIncident?.reason == "oom")
        #expect(snapshot.lastIncident?.restartedAt != nil)
        #expect(snapshot.lastIncident?.memoryLimitBytes == UInt64(4) * 1024 * 1024 * 1024)
        #expect(snapshot.bootId != initialBootId)
        #expect(await fixture.starts == 2)
        #expect(await fixture.routerResets == 1)
        #expect(await fixture.routerReconciles == 1)

        let data = try Data(contentsOf: root.appendingPathComponent("status.json"))
        let persisted = try JSONDecoder.withISO8601Dates.decode(ContainerRuntimeSnapshot.self, from: data)
        #expect(persisted.phase == snapshot.phase)
        #expect(persisted.bootId == snapshot.bootId)
        #expect(persisted.reason == snapshot.reason)
        #expect(persisted.lastIncident?.id == snapshot.lastIncident?.id)
        #expect(persisted.oomKillCount == snapshot.oomKillCount)
        #expect(persisted.hostResources?.cpuPercent == 12.5)
        #expect(persisted.hostResources?.memoryTotalBytes == UInt64(16) * 1024 * 1024 * 1024)
        #expect(persisted.vmResources == snapshot.vmResources)
        #expect(persisted.vmResources?.memoryResidentBytes == 1024 * 1024)
        #expect(persisted.vmResources?.memoryLimitBytes == UInt64(8192) * 1024 * 1024)
        #expect(persisted.vmResources?.diskAllocatedBytes == 1024 * 1024)
        #expect(persisted.vmResources?.diskTotalBytes == UInt64(20) * 1024 * 1024 * 1024)
        #expect(persisted.vmResources?.diskAvailableBytes == 0)
        #expect(persisted.vmResources?.diskFreeInodes == 631_409)
        #expect(abs(persisted.updatedAt.timeIntervalSince(snapshot.updatedAt)) < 1)

        try await supervisor.stop()
        #expect((await supervisor.snapshot()).vmResources == nil)
    }

    private func incidentTestRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/runtime-incidents/\(UUID().uuidString)")
    }

    private func incidentSupervisor(
        fixture: RuntimeFixture, root: URL,
        configuration: ContainerRuntimeSupervisor.Configuration = .init(diagnosticInterval: 0)
    ) -> ContainerRuntimeSupervisor {
        ContainerRuntimeSupervisor(
            configuration: configuration,
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil }, readVMResources: { _ in nil },
            sleep: { _ in }, onStatusChanged: { _ in }, log: { _ in }
        )
    }

    @Test func resourceRestartAppliesCurrentLimitsAndRestoresRoutingWithoutHostReserveGates() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gib: UInt64 = 1 << 30
        let configuredMemory = Mutex<UInt64>(4096)
        let appliedMemory = Mutex<[UInt64]>([])
        let events = Mutex<[String]>([])
        let phases = Mutex<[ContainerRuntimeSnapshot.Phase]>([])
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: {
                let memory = configuredMemory.withLock { $0 }
                appliedMemory.withLock { $0.append(memory) }
                events.withLock { $0.append("start:\(memory)") }
                return SmolVMStartupResult(machineName: "test", dockerSocketURL: root.appendingPathComponent("docker.sock"))
            }, stopMachine: { events.withLock { $0.append("stop") } },
            probeDocker: { true },
            readDiagnostics: {
                let memory = appliedMemory.withLock { $0.last ?? 4096 }
                return SmolVMMachine(name: "test", state: "running", labels: [:],
                    memory: SmolVMMemoryStatus(totalBytes: memory * 1_048_576,
                        availableBytes: gib, freeBytes: gib, buffersBytes: 0, cachedBytes: 0, oomKillCount: 0),
                    workload: nil, pid: Int32(memory), memoryMiB: memory)
            }, resetRouter: { events.withLock { $0.append("reset router") } },
            reconcileRouter: { events.withLock { $0.append("restore router") } },
            readHostResources: {
                HostResourceSnapshot(cpuPercent: nil, cpuCount: 8, memoryUsedBytes: 15 * gib,
                    memoryTotalBytes: 16 * gib, diskUsedBytes: 99 * gib, diskTotalBytes: 100 * gib)
            }, readVMResources: { _ in nil },
            onStatusChanged: { snapshot in phases.withLock { $0.append(snapshot.phase) } }, log: { _ in }
        )
        try await supervisor.start()
        let initialBootId = (await supervisor.snapshot()).bootId
        configuredMemory.withLock { $0 = 8192 }
        try await supervisor.restart()
        let snapshot = await supervisor.snapshot()
        #expect(appliedMemory.withLock { $0 } == [4096, 8192])
        #expect(events.withLock { $0 } == ["start:4096", "reset router", "start:8192", "restore router"])
        #expect(phases.withLock { $0 } == [.starting, .healthy, .restarting, .healthy])
        #expect(snapshot.memoryTotalBytes == 8 * gib)
        #expect(snapshot.bootId != initialBootId)
        #expect(snapshot.phase == .healthy)
        #expect(HostResourcePolicy.warnings(for: snapshot.hostResources).count == 2)
    }

    @Test(arguments: ["increased", "unchanged", "not-applied", "failed", "new-oom", "unknown-limit"])
    func memoryResizeClearsOnlyTheResolvedOOMWarning(outcome: String) async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let increased = outcome != "unchanged" && outcome != "not-applied" && outcome != "failed"
        var restarted = machine(oomKillCount: outcome == "new-oom" ? 1 : 0,
            pid: 456, memoryMiB: increased ? 8192 : 4096)
        if outcome == "unknown-limit" { restarted.memoryMiB = nil }
        let fixture = RuntimeFixture(probes: [true, true], diagnostics: [
            machine(oomKillCount: 0), machine(oomKillCount: 1), restarted,
            machine(oomKillCount: 1, pid: 456, memoryMiB: 8192),
        ])
        let messages = Mutex<[String]>([])
        let supervisor = ContainerRuntimeSupervisor(
            configuration: .init(diagnosticInterval: 0),
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: {
                let result = await fixture.start()
                let starts = await fixture.starts
                if outcome == "failed", starts > 1 {
                    throw SmolVMSetupError.dockerStartupFailed("resize failed")
                }
                return result
            }, stopMachine: {}, probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() }, resetRouter: {}, reconcileRouter: {},
            readHostResources: { nil }, readVMResources: { _ in nil },
            onStatusChanged: { _ in }, log: { message in messages.withLock { $0.append(message) } }
        )
        try await supervisor.start()
        await supervisor.reconcile()
        let incident = try #require((await supervisor.snapshot()).lastIncident)
        do {
            try await supervisor.restart(afterMemoryIncreaseTo: outcome == "unchanged" ? nil : 8192)
            #expect(outcome != "failed")
        } catch {
            #expect(outcome == "failed")
        }
        let snapshot = await supervisor.snapshot()
        if outcome == "increased" {
            #expect(snapshot.phase == .healthy)
            #expect(snapshot.lastIncident == nil)
            #expect(!snapshot.menuDescription.contains("out of memory"))
            let data = try Data(contentsOf: root.appendingPathComponent("status.json"))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(payload["lastIncident"] == nil)
            let reopened = ContainerRuntimeStatusStore(directoryURL: root)
            #expect((await reopened.snapshot()).lastIncident == nil)
            #expect(messages.withLock { $0.contains { $0.contains("OOM incident \(incident.id) resolved") } })
            // Clearing the old incident must not suppress a later OOM.
            await supervisor.reconcile()
            let nextIncident = try #require((await supervisor.snapshot()).lastIncident)
            #expect(nextIncident.id != incident.id)
            #expect(nextIncident.memoryLimitBytes == UInt64(8) << 30)
        } else if outcome == "new-oom" {
            #expect(snapshot.lastIncident?.id != incident.id)
            #expect(snapshot.lastIncident?.memoryLimitBytes == UInt64(8) << 30)
        } else {
            #expect(snapshot.lastIncident?.id == incident.id)
        }
    }

    @Test func resourceRestartWaitsForStartupAndCancelledRestartDoesNotRunDuringShutdown() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let starts = Mutex(0)
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: {
                let count = starts.withLock { $0 += 1; return $0 }
                if count == 1 {
                    entry.yield(())
                    var iterator = released.makeAsyncIterator()
                    await iterator.next()
                }
                return SmolVMStartupResult(machineName: "test", dockerSocketURL: root.appendingPathComponent("docker.sock"))
            }, stopMachine: {}, probeDocker: { true },
            readDiagnostics: { self.machine(oomKillCount: 0) }, resetRouter: {}, reconcileRouter: {},
            readHostResources: { nil }, readVMResources: { _ in nil }, onStatusChanged: { _ in }, log: { _ in }
        )
        let startup = Task { try await supervisor.start() }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        let restart = Task { try await supervisor.restart() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(starts.withLock { $0 } == 1)
        restart.cancel()
        let shutdown = Task { try await supervisor.stop() }
        release.yield(())
        _ = try await startup.value
        await #expect(throws: CancellationError.self) { try await restart.value }
        try await shutdown.value
        #expect(starts.withLock { $0 } == 1)
        #expect((await supervisor.snapshot()).phase == .stopped)
    }

    @Test func resourceRestartCancelsCleanupBeforeRestartingTheMachine() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let events = Mutex<[String]>([])
        let maintenance = ContainerRuntimeMaintenance(stateURL: root.appendingPathComponent("maintenance.json"), execute: { _ in
            entry.yield(())
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                events.withLock { $0.append("cleanup cancelled") }
                throw error
            }
            return SmolVMCommandResult(standardOutput: "", standardError: "", exitCode: 0)
        }, log: { _ in })
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root), maintenance: maintenance,
            startMachine: {
                events.withLock { $0.append("start") }
                return SmolVMStartupResult(machineName: "test", dockerSocketURL: root.appendingPathComponent("docker.sock"))
            }, stopMachine: {}, probeDocker: { true },
            readDiagnostics: { self.machine(oomKillCount: 0) }, resetRouter: {}, reconcileRouter: {},
            readHostResources: { nil }, readVMResources: { _ in nil }, onStatusChanged: { _ in }, log: { _ in }
        )
        try await supervisor.start()
        _ = await supervisor.runMaintenance()
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        try await supervisor.restart()
        #expect(events.withLock { $0 } == ["start", "cleanup cancelled", "start"])
        #expect(!(await maintenance.snapshot()).running)
        #expect((await supervisor.snapshot()).phase == .healthy)
    }

    @Test func oldProbeCannotTriggerRecoveryAfterAResourceRestart() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let starts = Mutex(0)
        let supervisor = ContainerRuntimeSupervisor(
            configuration: .init(failureThreshold: 1, recoveryBackoff: .zero),
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: {
                starts.withLock { $0 += 1 }
                return SmolVMStartupResult(machineName: "test", dockerSocketURL: root.appendingPathComponent("docker.sock"))
            }, stopMachine: {}, probeDocker: {
                entry.yield(())
                var iterator = released.makeAsyncIterator()
                await iterator.next()
                return false
            }, readDiagnostics: { self.machine(oomKillCount: 0, workloadExited: true) },
            resetRouter: {}, reconcileRouter: {}, readHostResources: { nil }, readVMResources: { _ in nil },
            onStatusChanged: { _ in }, log: { _ in }
        )
        try await supervisor.start()
        let probe = Task { await supervisor.reconcile() }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        try await supervisor.restart()
        release.yield(())
        await probe.value
        #expect(starts.withLock { $0 } == 2)
        #expect((await supervisor.snapshot()).phase == .healthy)
    }

    @Test func firstMissedProbePublishesOOMBeforeTheRestartThreshold() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(probes: [false],
                                     diagnostics: [machine(oomKillCount: 0), machine(oomKillCount: 1)])
        let supervisor = incidentSupervisor(fixture: fixture, root: root)
        _ = try await supervisor.start()
        await supervisor.reconcile()
        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .degraded)
        #expect(snapshot.reason == "oom")
        #expect(snapshot.message.contains("out of memory"))
        #expect(snapshot.lastIncident?.reason == "oom")
        #expect(await fixture.starts == 1)
    }

    @Test func startupOOMIsRecordedEvenWhenDockerNeverBecomesReady() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { throw SmolVMSetupError.dockerSocketUnavailable("test.sock") },
            stopMachine: {}, probeDocker: { false },
            readDiagnostics: { machine(oomKillCount: 1, workloadOOM: true) },
            resetRouter: {}, reconcileRouter: {}, readHostResources: { nil }, readVMResources: { _ in nil },
            onStatusChanged: { _ in }, log: { _ in }
        )
        do {
            _ = try await supervisor.start()
            Issue.record("Startup should fail")
        } catch {}
        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .failed)
        #expect(snapshot.reason == "oom")
        #expect(snapshot.lastIncident?.reason == "oom")
        #expect(snapshot.message.contains("out of memory while starting"))
    }

    @Test func failedStartupKeepsHostReservesCurrentWithoutRetryingTheVM() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gib: UInt64 = 1 << 30
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let used = Mutex(13 * gib)
        let starts = Mutex(0)
        let failure = SmolVMSetupError.dockerStartupFailed("Docker workload exited")
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { starts.withLock { $0 += 1 }; throw failure },
            stopMachine: {}, probeDocker: { false }, readDiagnostics: { throw failure },
            resetRouter: {}, reconcileRouter: {},
            readHostResources: {
                HostResourceSnapshot(cpuPercent: nil, cpuCount: 8, memoryUsedBytes: used.withLock { $0 },
                    memoryTotalBytes: 16 * gib, diskUsedBytes: nil, diskTotalBytes: nil)
            }, readVMResources: { _ in nil }, now: { clock.withLock { $0 } },
            onStatusChanged: { _ in }, log: { _ in }
        )
        do { _ = try await supervisor.start() } catch {}
        #expect(HostResourcePolicy.warnings(for: (await supervisor.snapshot()).hostResources).count == 1)
        used.withLock { $0 = 10 * gib }
        clock.withLock { $0.addTimeInterval(10) }
        await supervisor.reconcile()
        let refreshed = await supervisor.snapshot()
        #expect(HostResourcePolicy.warnings(for: refreshed.hostResources).isEmpty)
        #expect(refreshed.phase == .failed)
        #expect(refreshed.message == failure.localizedDescription)
        #expect(starts.withLock { $0 } == 1)
    }

    @Test func healthySamplesRetainOOMWithoutRestartingRunningContainers() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(probes: [true, true],
                                     diagnostics: [machine(oomKillCount: 0), machine(oomKillCount: 1)])
        let supervisor = incidentSupervisor(fixture: fixture, root: root)
        _ = try await supervisor.start()
        await supervisor.reconcile()
        let first = await supervisor.snapshot()
        #expect(first.phase == .healthy)
        let incident = try #require(first.lastIncident)
        await supervisor.reconcile()
        let next = await supervisor.snapshot()
        #expect(next.lastIncident?.id == incident.id)
        #expect(next.lastIncident?.restartedAt == nil)
        #expect(next.menuDescription.contains("out of memory"))
        #expect(await fixture.starts == 1)
        #expect(await fixture.stops == 0)
    }

    @Test func launcherRelaunchPreservesTheIncidentButClearsStaleReadiness() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(probes: [true],
                                     diagnostics: [machine(oomKillCount: 0), machine(oomKillCount: 1)])
        let supervisor = incidentSupervisor(fixture: fixture, root: root)
        _ = try await supervisor.start()
        await supervisor.reconcile()
        let incident = try #require((await supervisor.snapshot()).lastIncident)

        let relaunched = incidentSupervisor(fixture: RuntimeFixture(probes: [],
                                              diagnostics: [machine(oomKillCount: 0)]), root: root)
        await relaunched.prepareForLaunch()
        #expect((await relaunched.snapshot()).phase == .starting)
        #expect((await relaunched.snapshot()).lastIncident?.id == incident.id)
        _ = try await relaunched.start()
        let recovered = await relaunched.snapshot()
        #expect(recovered.phase == .healthy)
        #expect(recovered.oomKillCount == 0)
        #expect(recovered.lastIncident?.id == incident.id)
    }

    @Test func exhaustedOOMRecoveryKeepsTheActionableCause() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(probes: [false, false], diagnostics: [
            machine(oomKillCount: 0), machine(oomKillCount: 1, workloadOOM: true),
            machine(oomKillCount: 0), machine(oomKillCount: 1, workloadOOM: true),
        ])
        let supervisor = incidentSupervisor(fixture: fixture, root: root,
            configuration: .init(failureThreshold: 1, maximumRecoveries: 1, recoveryBackoff: .zero))
        _ = try await supervisor.start()
        await supervisor.reconcile()
        await supervisor.reconcile()
        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .failed)
        #expect(snapshot.reason == "oom")
        #expect(snapshot.message.contains("Increase VM memory"))
        #expect(snapshot.lastIncident?.reason == "oom")
        #expect(await fixture.starts == 2)
    }

    @Test func relaunchDoesNotCreateANewIncidentForAnAlreadyReportedKernelCounter() async throws {
        let root = incidentTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = incidentSupervisor(fixture: RuntimeFixture(probes: [],
            diagnostics: [machine(oomKillCount: 1)]), root: root)
        _ = try await original.start()
        let incident = try #require((await original.snapshot()).lastIncident)
        let relaunched = incidentSupervisor(fixture: RuntimeFixture(probes: [true],
            diagnostics: [machine(oomKillCount: 1), machine(oomKillCount: 2)]), root: root)
        _ = try await relaunched.start()
        #expect((await relaunched.snapshot()).lastIncident?.id == incident.id)
        await relaunched.reconcile()
        #expect((await relaunched.snapshot()).lastIncident?.id != incident.id)
    }

    @Test func transientProbeFailureDoesNotRestartTheVM() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(
            probes: [false, true],
            diagnostics: [machine(oomKillCount: 0)]
        )
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil },
            readVMResources: { _ in nil },
            sleep: { _ in },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        _ = try await supervisor.start()
        let initialBootId = try #require((await supervisor.snapshot()).bootId)
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .degraded)
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .healthy)
        #expect((await supervisor.snapshot()).bootId == initialBootId)
        #expect(await fixture.starts == 1)
        #expect(await fixture.routerResets == 0)
    }

    @Test func preparingHostListenersClearsAStaleHealthySnapshot() async throws {
        let macosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = macosRoot.appendingPathComponent(".build/runtime-startup-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContainerRuntimeStatusStore(directoryURL: root)
        let fixture = RuntimeFixture(probes: [true], diagnostics: [machine(oomKillCount: 0)])
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: store,
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil },
            readVMResources: { _ in nil },
            sleep: { _ in },
            onStatusChanged: { _ in }, log: { _ in }
        )
        var stale = await supervisor.snapshot()
        stale = ContainerRuntimeSnapshot(phase: .healthy, message: "old launch", reason: nil,
            updatedAt: stale.updatedAt, recoveryAttempt: nil, memoryTotalBytes: nil,
            memoryAvailableBytes: nil, oomKillCount: nil, hostResources: nil, bootId: "old-boot")
        try await store.publish(stale)
        await supervisor.prepareForLaunch()
        #expect((await supervisor.snapshot()).phase == .starting)
        #expect((await supervisor.snapshot()).bootId == nil)
        _ = try await supervisor.start()
        let bootId = (await supervisor.snapshot()).bootId
        await supervisor.prepareForLaunch()
        #expect((await supervisor.snapshot()).phase == .healthy)
        #expect((await supervisor.snapshot()).bootId == bootId)
    }

    @Test func repeatedFailuresStopAtTheRecoveryLimit() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(
            probes: [false, false],
            diagnostics: [machine(oomKillCount: 0, workloadExited: true)]
        )
        let supervisor = ContainerRuntimeSupervisor(
            configuration: .init(
                failureThreshold: 1,
                maximumRecoveries: 1,
                recoveryWindow: 600,
                diagnosticInterval: 60,
                recoveryBackoff: .zero
            ),
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil },
            readVMResources: { _ in nil },
            sleep: { _ in },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        _ = try await supervisor.start()
        await supervisor.reconcile()
        await supervisor.reconcile()

        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .failed)
        #expect(snapshot.reason == "recovery_exhausted")
        #expect(await fixture.starts == 2)
    }

    @Test func busyDockerDoesNotRestartRunningContainersEvenAfterAnOOM() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(
            probes: [false, false, false, false, true],
            diagnostics: [machine(oomKillCount: 0), machine(oomKillCount: 1)]
        )
        let supervisor = ContainerRuntimeSupervisor(
            configuration: .init(failureThreshold: 1, diagnosticInterval: 60),
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { await fixture.start() },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil },
            readVMResources: { _ in nil },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        _ = try await supervisor.start()
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .degraded)
        #expect((await supervisor.snapshot()).reason == "oom")
        for _ in 0..<4 { await supervisor.reconcile() }
        #expect((await supervisor.snapshot()).phase == .healthy)
        #expect(await fixture.starts == 1)
        #expect(await fixture.stops == 0)
        #expect(await fixture.routerResets == 0)
    }

    @Test func lateDockerReadinessClearsStartupFailureWithoutAnotherStart() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(probes: [false, true], diagnostics: [machine(oomKillCount: 0)])
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { throw SmolVMSetupError.dockerSocketUnavailable("test.sock") },
            stopMachine: { await fixture.stop() },
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
            resetRouter: { await fixture.resetRouter() },
            reconcileRouter: { await fixture.reconcileRouter() },
            readHostResources: { nil },
            readVMResources: { _ in nil },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        do {
            _ = try await supervisor.start()
            Issue.record("Startup should have timed out")
        } catch {}
        #expect((await supervisor.snapshot()).phase == .failed)
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .failed)
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .healthy)
        #expect(await fixture.starts == 0)
        #expect(await fixture.routerResets == 0)
    }

    @Test func startupFailurePublishesAndRetainsTheActualDockerError() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-startup-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let logStore = SystemLogStore(directoryURL: root.appendingPathComponent("logs"))
        let failure = SmolVMSetupError.dockerStartupFailed("error initializing buildkit: invalid suffix: %")
        let supervisor = ContainerRuntimeSupervisor(
            statusStore: ContainerRuntimeStatusStore(directoryURL: root),
            startMachine: { throw failure },
            stopMachine: {},
            probeDocker: { false },
            readDiagnostics: { throw failure },
            resetRouter: {},
            reconcileRouter: {},
            readHostResources: { nil },
            readVMResources: { _ in nil },
            onStatusChanged: { _ in },
            log: { logStore.append("runtime", $0) }
        )
        do {
            _ = try await supervisor.start()
            Issue.record("Startup should have failed")
        } catch {
            #expect(error.localizedDescription == failure.localizedDescription)
        }
        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .failed)
        #expect(snapshot.message == failure.localizedDescription)
        let persisted = try JSONDecoder.withISO8601Dates.decode(
            ContainerRuntimeSnapshot.self, from: Data(contentsOf: root.appendingPathComponent("status.json"))
        )
        #expect(persisted.message == failure.localizedDescription)
        await logStore.flush()
        let reopened = SystemLogStore(directoryURL: logStore.directoryURL)
        #expect(await reopened.history(sources: ["runtime"]).entries.last?.line.contains(failure.localizedDescription) == true)
    }

    @Test func machineStatusDecodesOldAndDiagnosticJSON() throws {
        let old = Data(#"{"name":"test","state":"running","labels":{}}"#.utf8)
        let oldMachine = try JSONDecoder().decode(SmolVMMachine.self, from: old)
        #expect(oldMachine.memory == nil)
        #expect(oldMachine.workload == nil)
        #expect(oldMachine.pid == nil)
        #expect(oldMachine.memoryMiB == nil)

        let host = Data(#"{"name":"test","state":"running","pid":123,"memory_mib":8192}"#.utf8)
        let hostMachine = try JSONDecoder().decode(SmolVMMachine.self, from: host)
        #expect(hostMachine.pid == 123)
        #expect(hostMachine.memoryMiB == 8192)

        let current = Data(#"{"name":"test","state":"running","labels":{},"memory":{"total_bytes":4096,"available_bytes":2048,"free_bytes":1024,"buffers_bytes":128,"cached_bytes":512,"oom_kill_count":2},"workload":{"state":"exited","last_exit_code":137,"last_exit_reason":"oom_killed","oom_killed":true}}"#.utf8)
        let machine = try JSONDecoder().decode(SmolVMMachine.self, from: current)
        #expect(machine.memory?.oomKillCount == 2)
        #expect(machine.workload?.oomKilled == true)
    }
}

private extension JSONDecoder {
    static var withISO8601Dates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
