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
    private func machine(oomKillCount: UInt64, workloadOOM: Bool = false) -> SmolVMMachine {
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
                state: workloadOOM ? "exited" : "running",
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
        #expect(abs(persisted.updatedAt.timeIntervalSince(snapshot.updatedAt)) < 1)
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
            diagnostics: [machine(oomKillCount: 0)]
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

    @Test func machineStatusDecodesOldAndDiagnosticJSON() throws {
        let old = Data(#"{"name":"test","state":"running","labels":{}}"#.utf8)
        let oldMachine = try JSONDecoder().decode(SmolVMMachine.self, from: old)
        #expect(oldMachine.memory == nil)
        #expect(oldMachine.workload == nil)

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
