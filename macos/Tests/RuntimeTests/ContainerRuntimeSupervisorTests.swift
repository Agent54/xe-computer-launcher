import Foundation
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
    private func machine(oomKillCount: UInt64, workloadOOM: Bool = false, workloadExited: Bool = false) -> SmolVMMachine {
        SmolVMMachine(
            name: "test",
            state: "running",
            labels: [:],
            memory: SmolVMMemoryStatus(
                totalBytes: 4 * 1024 * 1024 * 1024,
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
            )
        )
    }

    @Test func oomRestartsTheWholeRuntimeAndPublishesCause() async throws {
        let root = URL(fileURLWithPath: "/tmp/xe-runtime-status-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeFixture(
            probes: [false, false, false],
            diagnostics: [machine(oomKillCount: 0), machine(oomKillCount: 1, workloadOOM: true), machine(oomKillCount: 0)]
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
                    balloonTargetBytes: 0,
                    balloonInflatedBytes: 0,
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
        await supervisor.reconcile()
        await supervisor.reconcile()
        await supervisor.reconcile()

        let snapshot = await supervisor.snapshot()
        #expect(snapshot.phase == .healthy)
        #expect(snapshot.reason == "oom_recovered")
        #expect(await fixture.starts == 2)
        #expect(await fixture.routerResets == 1)
        #expect(await fixture.routerReconciles == 1)

        let data = try Data(contentsOf: root.appendingPathComponent("status.json"))
        let persisted = try JSONDecoder.withISO8601Dates.decode(ContainerRuntimeSnapshot.self, from: data)
        #expect(persisted.phase == snapshot.phase)
        #expect(persisted.reason == snapshot.reason)
        #expect(persisted.oomKillCount == snapshot.oomKillCount)
        #expect(persisted.hostResources?.cpuPercent == 12.5)
        #expect(persisted.hostResources?.memoryTotalBytes == UInt64(16) * 1024 * 1024 * 1024)
        #expect(persisted.vmResources == snapshot.vmResources)
        #expect(persisted.vmResources?.balloonInflatedBytes == 0)
        #expect(persisted.vmResources?.diskAllocatedBytes == 1024 * 1024)
        #expect(persisted.vmResources?.diskTotalBytes == UInt64(20) * 1024 * 1024 * 1024)
        #expect(persisted.vmResources?.diskAvailableBytes == 0)
        #expect(persisted.vmResources?.diskFreeInodes == 631_409)
        #expect(abs(persisted.updatedAt.timeIntervalSince(snapshot.updatedAt)) < 1)

        try await supervisor.stop()
        #expect((await supervisor.snapshot()).vmResources == nil)
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
            sleep: { _ in },
            onStatusChanged: { _ in },
            log: { _ in }
        )

        _ = try await supervisor.start()
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .degraded)
        await supervisor.reconcile()
        #expect((await supervisor.snapshot()).phase == .healthy)
        #expect(await fixture.starts == 1)
        #expect(await fixture.routerResets == 0)
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
            probeDocker: { await fixture.probe() },
            readDiagnostics: { await fixture.diagnostic() },
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
