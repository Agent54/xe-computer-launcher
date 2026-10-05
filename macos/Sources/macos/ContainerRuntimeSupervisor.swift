import Foundation

struct ContainerRuntimeSnapshot: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting
        case healthy
        case degraded
        case diagnosing
        case restarting
        case failed
        case stopped
    }

    let phase: Phase
    let message: String
    let reason: String?
    let updatedAt: Date
    let recoveryAttempt: Int?
    let memoryTotalBytes: UInt64?
    let memoryAvailableBytes: UInt64?
    let oomKillCount: UInt64?
    let hostResources: HostResourceSnapshot?
    var vmResources: VMResourceSnapshot? = nil
    var bootId: String? = nil

    var menuDescription: String { message }
}

@MainActor
final class ContainerRuntimePresentation {
    static let shared = ContainerRuntimePresentation()
    private(set) var snapshot = ContainerRuntimeSnapshot(
        phase: .starting,
        message: "Starting container runtime…",
        reason: nil,
        updatedAt: Date(),
        recoveryAttempt: nil,
        memoryTotalBytes: nil,
        memoryAvailableBytes: nil,
        oomKillCount: nil,
        hostResources: nil
    )

    func update(_ snapshot: ContainerRuntimeSnapshot) {
        self.snapshot = snapshot
    }
}

actor ContainerRuntimeStatusStore {
    static var directoryURL: URL {
        ExternalState.appDataURL.appendingPathComponent("runtime-status", isDirectory: true)
    }

    private let directoryURL: URL
    private var current: ContainerRuntimeSnapshot

    init(directoryURL: URL = ContainerRuntimeStatusStore.directoryURL) {
        self.directoryURL = directoryURL
        self.current = ContainerRuntimeSnapshot(
            phase: .starting,
            message: "Starting container runtime…",
            reason: nil,
            updatedAt: Date(),
            recoveryAttempt: nil,
            memoryTotalBytes: nil,
            memoryAvailableBytes: nil,
            oomKillCount: nil,
            hostResources: nil
        )
    }

    func publish(_ snapshot: ContainerRuntimeSnapshot) throws {
        current = snapshot
        let fm = FileManager.default
        try fm.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: directoryURL.appendingPathComponent("status.json"), options: .atomic)
    }

    func snapshot() -> ContainerRuntimeSnapshot { current }
}

actor ContainerRuntimeSupervisor {
    struct Configuration: Sendable {
        var failureThreshold = 3
        var maximumRecoveries = 3
        var recoveryWindow: TimeInterval = 10 * 60
        var diagnosticInterval: TimeInterval = 10
        var recoveryBackoff: Duration = .seconds(1)
    }

    typealias StartMachine = @Sendable () async throws -> SmolVMStartupResult
    typealias StopMachine = @Sendable () async throws -> Void
    typealias ProbeDocker = @Sendable () async -> Bool
    typealias ReadDiagnostics = @Sendable () async throws -> SmolVMMachine
    typealias RouterReset = @Sendable () async -> Void
    typealias RouterReconcile = @Sendable () async throws -> Void
    typealias ReadHostResources = @Sendable () async -> HostResourceSnapshot?
    typealias ReadVMResources = @Sendable (SmolVMMachine?) async -> VMResourceSnapshot?
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias StatusChanged = @Sendable (ContainerRuntimeSnapshot) async -> Void
    typealias Log = @Sendable (String) -> Void

    private enum State {
        case idle
        case starting
        case healthy
        case degraded
        case recovering
        case failed
        case stopped
    }

    private let configuration: Configuration
    private let statusStore: ContainerRuntimeStatusStore
    private let startMachine: StartMachine
    private let stopMachine: StopMachine
    private let probeDocker: ProbeDocker
    private let readDiagnostics: ReadDiagnostics
    private let resetRouter: RouterReset
    private let reconcileRouter: RouterReconcile
    private let readHostResources: ReadHostResources
    private let readVMResources: ReadVMResources
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let onStatusChanged: StatusChanged
    private let log: Log
    private let maintenance: ContainerRuntimeMaintenance?

    private var state = State.idle
    private var consecutiveFailures = 0
    private var recoveryDates: [Date] = []
    private var lastDiagnosticsAt = Date.distantPast
    private var lastDiagnostics: SmolVMMachine?
    private var bootId: String?

    init(
        configuration: Configuration = Configuration(),
        statusStore: ContainerRuntimeStatusStore = ContainerRuntimeStatusStore(),
        maintenance: ContainerRuntimeMaintenance? = nil,
        startMachine: @escaping StartMachine = { try await SmolVMSetup.start() },
        stopMachine: @escaping StopMachine = { try await SmolVMSetup.stop() },
        probeDocker: @escaping ProbeDocker = {
            await UnixSocketHTTP.isReady(at: SmolVMSetup.dockerSocketURL, timeout: .milliseconds(750))
        },
        readDiagnostics: @escaping ReadDiagnostics = {
            try await SmolVMClient.shared.machineStatus(named: SmolVMSetup.machineName)
        },
        resetRouter: @escaping RouterReset = { GuestRouter.shared.reset() },
        reconcileRouter: @escaping RouterReconcile = { try await GuestRouter.shared.reconcile() },
        readHostResources: @escaping ReadHostResources = { await HostResourceSampler.shared.snapshot() },
        readVMResources: @escaping ReadVMResources = { await VMResourceSampler.snapshot(machine: $0) },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        onStatusChanged: @escaping StatusChanged = { snapshot in
            Task { @MainActor in ContainerRuntimePresentation.shared.update(snapshot) }
        },
        log: @escaping Log = { ExternalState.shared.appendLog("runtime", $0) }
    ) {
        self.configuration = configuration
        self.statusStore = statusStore
        self.startMachine = startMachine
        self.stopMachine = stopMachine
        self.probeDocker = probeDocker
        self.readDiagnostics = readDiagnostics
        self.resetRouter = resetRouter
        self.reconcileRouter = reconcileRouter
        self.readHostResources = readHostResources
        self.readVMResources = readVMResources
        self.sleep = sleep
        self.now = now
        self.onStatusChanged = onStatusChanged
        self.log = log
        self.maintenance = maintenance
    }

    @discardableResult
    func start() async throws -> SmolVMStartupResult {
        state = .starting
        bootId = UUID().uuidString
        await publish(phase: .starting, message: "Starting container runtime…")
        do {
            let result = try await startMachine()
            consecutiveFailures = 0
            lastDiagnostics = try? await readDiagnostics()
            lastDiagnosticsAt = now()
            state = .healthy
            let memory = lastDiagnostics?.memory
            await publish(
                phase: .healthy,
                message: "Container runtime ready",
                memory: memory
            )
            log("Container runtime ready with " + String(SmolVMSetup.memoryMiB) + " MiB memory")
            return result
        } catch {
            state = .failed
            let detail = error.localizedDescription
            log("Container runtime failed to start: \(detail)")
            await publish(
                phase: .failed,
                message: detail,
                reason: "startup_failure"
            )
            throw error
        }
    }

    /// Clear a previous launch's healthy snapshot before starting host listeners.
    func prepareForLaunch() async {
        guard state == .idle else { return }
        await publish(phase: .starting, message: "Starting container runtime…")
    }

    func reconcile() async {
        guard state != .idle, state != .starting, state != .recovering,
              state != .stopped else { return }

        if await probeDocker() {
            guard state != .stopped, state != .recovering, state != .starting else { return }
            consecutiveFailures = 0
            if state == .degraded || state == .failed {
                state = .healthy
                await publish(
                    phase: .healthy,
                    message: "Container runtime ready",
                    memory: lastDiagnostics?.memory
                )
                log("Container runtime recovered without a restart")
            }
            await refreshDiagnosticsIfNeeded()
            if state == .healthy { await maintenance?.reconcile() }
            return
        }

        await maintenance?.pause()

        // A timed-out startup or exhausted recovery can still finish later.
        // Observe it without scheduling another restart.
        guard state != .failed, state != .stopped, state != .recovering,
              state != .starting else { return }

        consecutiveFailures += 1
        state = .degraded
        await publish(
            phase: .degraded,
            message: "Container runtime is not responding (\(consecutiveFailures)/\(configuration.failureThreshold))",
            reason: "docker_unavailable",
            memory: lastDiagnostics?.memory
        )
        guard consecutiveFailures >= configuration.failureThreshold else { return }
        await recover()
    }

    func stop() async throws {
        state = .stopped
        await maintenance?.pause()
        await publish(phase: .stopped, message: "Container runtime stopped")
        try await stopMachine()
    }

    func snapshot() async -> ContainerRuntimeSnapshot {
        await statusStore.snapshot()
    }

    func maintenanceSnapshot() async -> ContainerRuntimeMaintenance.Snapshot? {
        await maintenance?.snapshot()
    }

    func runMaintenance() async -> ContainerRuntimeMaintenance.Snapshot? {
        guard state == .healthy, let maintenance else { return nil }
        guard await maintenance.reconcile(force: true) != nil else { return nil }
        return await maintenance.snapshot()
    }

    private func refreshDiagnosticsIfNeeded() async {
        guard now().timeIntervalSince(lastDiagnosticsAt) >= configuration.diagnosticInterval else { return }
        if let diagnostics = try? await readDiagnostics() {
            lastDiagnostics = diagnostics
            lastDiagnosticsAt = now()
            await publish(
                phase: .healthy,
                message: "Container runtime ready",
                memory: diagnostics.memory
            )
        }
    }

    private func recover() async {
        state = .recovering
        await maintenance?.pause()
        let diagnosed = try? await readDiagnostics()
        let previousOOMCount = lastDiagnostics?.memory?.oomKillCount
        let currentOOMCount = diagnosed?.memory?.oomKillCount
        let workloadOOM = diagnosed?.workload?.oomKilled == true
        let oomCountAdvanced: Bool
        if let previousOOMCount, let currentOOMCount {
            oomCountAdvanced = currentOOMCount > previousOOMCount
        } else {
            oomCountAdvanced = false
        }
        let wasOOM = workloadOOM || oomCountAdvanced
        if let diagnosed { lastDiagnostics = diagnosed }

        // Docker's short health probe can time out during a heavy build.
        // Only restart after diagnostics confirm the VM or daemon exited.
        let daemonExited = ["exited", "stopped", "failed"].contains(diagnosed?.workload?.state.lowercased() ?? "")
        guard let diagnosed, !diagnosed.isRunning || daemonExited else {
            state = .degraded
            consecutiveFailures = 0
            await publish(
                phase: .degraded,
                message: wasOOM
                    ? "Container VM ran out of memory; waiting for Docker to respond…"
                    : "Docker is not responding; waiting without interrupting running containers…",
                reason: wasOOM ? "oom" : "docker_unavailable",
                memory: diagnosed?.memory
            )
            return
        }

        let cutoff = now().addingTimeInterval(-configuration.recoveryWindow)
        recoveryDates.removeAll { $0 < cutoff }
        guard recoveryDates.count < configuration.maximumRecoveries else {
            state = .failed
            let message = "Container runtime recovery stopped after repeated failures"
            await publish(
                phase: .failed,
                message: message,
                reason: "recovery_exhausted",
                memory: diagnosed.memory
            )
            log(message)
            return
        }

        recoveryDates.append(now())
        let attempt = recoveryDates.count
        let message = wasOOM
            ? "Container VM ran out of memory; restarting…"
            : "Container runtime stopped responding; restarting…"
        await publish(
            phase: .diagnosing,
            message: message,
            reason: wasOOM ? "oom" : "docker_unavailable",
            recoveryAttempt: attempt,
            memory: diagnosed.memory
        )
        log(message)

        await resetRouter()
        bootId = UUID().uuidString
        await publish(
            phase: .restarting,
            message: message,
            reason: wasOOM ? "oom" : "docker_unavailable",
            recoveryAttempt: attempt,
            memory: diagnosed.memory
        )

        do {
            try await sleep(configuration.recoveryBackoff)
            _ = try await startMachine()
            try await reconcileRouter()
            lastDiagnostics = try? await readDiagnostics()
            lastDiagnosticsAt = now()
            consecutiveFailures = 0
            state = .healthy
            await publish(
                phase: .healthy,
                message: "Container runtime recovered",
                reason: wasOOM ? "oom_recovered" : "docker_recovered",
                recoveryAttempt: attempt,
                memory: lastDiagnostics?.memory
            )
            log("Container runtime recovered after automatic VM restart")
        } catch is CancellationError {
            // App shutdown cancels the host-services task while recovery may be
            // sleeping or restarting SmolVM. The shutdown path publishes the
            // final stopped state; do not misreport that cancellation as a
            // failed automatic recovery in the meantime.
            return
        } catch {
            state = .degraded
            consecutiveFailures = configuration.failureThreshold
            let detail = error.localizedDescription
            await publish(
                phase: .degraded,
                message: "Container runtime restart failed; retrying…",
                reason: "restart_failed",
                recoveryAttempt: attempt,
                memory: lastDiagnostics?.memory
            )
            log("Container runtime restart failed: \(detail)")
        }
    }

    private func publish(
        phase: ContainerRuntimeSnapshot.Phase,
        message: String,
        reason: String? = nil,
        recoveryAttempt: Int? = nil,
        memory: SmolVMMemoryStatus? = nil
    ) async {
        let hostResources = await readHostResources()
        let machine = [.starting, .restarting, .stopped].contains(phase) ? nil : lastDiagnostics
        let vmResources = await readVMResources(machine)
        let snapshot = ContainerRuntimeSnapshot(
            phase: phase,
            message: message,
            reason: reason,
            updatedAt: now(),
            recoveryAttempt: recoveryAttempt,
            memoryTotalBytes: memory?.totalBytes,
            memoryAvailableBytes: memory?.availableBytes,
            oomKillCount: memory?.oomKillCount,
            hostResources: hostResources,
            vmResources: vmResources,
            bootId: bootId
        )
        do {
            try await statusStore.publish(snapshot)
        } catch {
            log("Could not publish container runtime status: " + error.localizedDescription)
        }
        await onStatusChanged(snapshot)
    }
}
