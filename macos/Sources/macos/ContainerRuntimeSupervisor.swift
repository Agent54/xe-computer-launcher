import Foundation

struct ContainerRuntimeIncident: Codable, Equatable, Sendable {
    let id: String
    let reason: String
    let message: String
    let occurredAt: Date
    let memoryLimitBytes: UInt64?
    var guestPID: Int32? = nil
    var oomKillCount: UInt64? = nil
    var restartedAt: Date? = nil
}

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
    var lastIncident: ContainerRuntimeIncident? = nil
    var cachePressureWarning: ContainerRuntimeMaintenance.CachePressureWarning? = nil

    var menuDescription: String {
        phase == .healthy && lastIncident?.reason == "oom"
            ? "\(message) · Last VM failure: out of memory"
            : message
    }
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
        // Restore the diagnosis, never the previous process's readiness.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: directoryURL.appendingPathComponent("status.json")),
           let previous = try? decoder.decode(ContainerRuntimeSnapshot.self, from: data) {
            self.current.lastIncident = previous.lastIncident
        }
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
    private var lastIncident: ContainerRuntimeIncident?
    private var didLoadIncident = false
    private var outageWasOOM = false

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
        await loadIncidentIfNeeded()
        state = .starting
        outageWasOOM = false
        bootId = UUID().uuidString
        await publish(phase: .starting, message: "Starting container runtime…")
        do {
            let result = try await startMachine()
            consecutiveFailures = 0
            if let diagnostics = try? await readDiagnostics() { observeDiagnostics(diagnostics) }
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
            if let diagnostics = try? await readDiagnostics() {
                outageWasOOM = observeDiagnostics(diagnostics)
            }
            state = .failed
            let detail = error.localizedDescription
            log("Container runtime failed to start: \(detail)")
            await publish(
                phase: .failed,
                message: outageWasOOM ? "Container VM ran out of memory while starting. \(detail)" : detail,
                reason: outageWasOOM ? "oom" : "startup_failure",
                memory: lastDiagnostics?.memory
            )
            throw error
        }
    }

    /// Clear a previous launch's healthy snapshot before starting host listeners.
    func prepareForLaunch() async {
        guard state == .idle else { return }
        await loadIncidentIfNeeded()
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
                    reason: outageWasOOM ? "oom_recovered" : nil,
                    memory: lastDiagnostics?.memory
                )
                log("Container runtime recovered without a restart")
            }
            outageWasOOM = false
            await refreshDiagnosticsIfNeeded()
            let resources = await statusStore.snapshot().vmResources
            if state == .healthy { await maintenance?.reconcile(resources: resources) }
            return
        }

        await maintenance?.pause()

        // A timed-out startup or exhausted recovery can still finish later.
        // Observe it without scheduling another restart.
        guard state != .failed, state != .stopped, state != .recovering,
              state != .starting else { return }

        consecutiveFailures += 1
        // Read the cause on the first missed probe. Waiting for the restart
        // threshold can lose an OOM to a later healthy sample or VM reboot.
        let diagnosed = try? await readDiagnostics()
        guard state != .stopped, state != .starting, state != .recovering else { return }
        if let diagnosed {
            let newOOM = observeDiagnostics(diagnosed)
            if newOOM || diagnosed.workload?.oomKilled == true { outageWasOOM = true }
        }
        state = .degraded
        await publish(
            phase: .degraded,
            message: outageWasOOM
                ? "Container VM ran out of memory; Docker is not responding (\(consecutiveFailures)/\(configuration.failureThreshold))"
                : "Container runtime is not responding (\(consecutiveFailures)/\(configuration.failureThreshold))",
            reason: outageWasOOM ? "oom" : "docker_unavailable",
            memory: lastDiagnostics?.memory
        )
        guard consecutiveFailures >= configuration.failureThreshold else { return }
        await recover(diagnosed: diagnosed)
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
            guard state == .healthy else { return }
            observeDiagnostics(diagnostics)
            await publish(
                phase: .healthy,
                message: "Container runtime ready",
                memory: diagnostics.memory
            )
        }
    }

    private func loadIncidentIfNeeded() async {
        guard !didLoadIncident else { return }
        didLoadIncident = true
        lastIncident = await statusStore.snapshot().lastIncident
    }

    /// Observe every diagnostic sample, including samples taken while Docker
    /// answers probes. The kernel may kill a build process without killing Docker.
    @discardableResult
    private func observeDiagnostics(_ diagnostics: SmolVMMachine) -> Bool {
        let sameGuest = lastDiagnostics?.pid == diagnostics.pid
        let resumingGuest = lastDiagnostics == nil && diagnostics.pid != nil
            && diagnostics.pid == lastIncident?.guestPID
        let previousCount = sameGuest ? lastDiagnostics?.memory?.oomKillCount ?? 0
            : resumingGuest ? lastIncident?.oomKillCount ?? 0 : 0
        let currentCount = diagnostics.memory?.oomKillCount ?? 0
        let workloadOOM = diagnostics.workload?.oomKilled == true
            && !resumingGuest && (!sameGuest || lastDiagnostics?.workload?.oomKilled != true)
        let newOOM = currentCount > previousCount || workloadOOM
        lastDiagnostics = diagnostics
        lastDiagnosticsAt = now()
        if newOOM {
            let incident = ContainerRuntimeIncident(
                id: UUID().uuidString,
                reason: "oom",
                message: "The container VM ran out of memory and Linux killed a process. Increase VM memory in Xe Launcher or run fewer builds at once.",
                occurredAt: now(),
                memoryLimitBytes: diagnostics.memory?.totalBytes,
                guestPID: diagnostics.pid,
                oomKillCount: diagnostics.memory?.oomKillCount
            )
            lastIncident = incident
            log(incident.message)
        }
        return newOOM
    }

    private func recover(diagnosed: SmolVMMachine?) async {
        state = .recovering
        await maintenance?.pause()
        let wasOOM = outageWasOOM
        let incidentID = lastIncident?.id

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
            let message = wasOOM
                ? "Container VM repeatedly ran out of memory; automatic recovery stopped. Increase VM memory in Xe Launcher or run fewer builds at once."
                : "Container runtime recovery stopped after repeated failures"
            await publish(
                phase: .failed,
                message: message,
                reason: wasOOM ? "oom" : "recovery_exhausted",
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
            if let diagnostics = try? await readDiagnostics() { observeDiagnostics(diagnostics) }
            if wasOOM, lastIncident?.id == incidentID { lastIncident?.restartedAt = now() }
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
            outageWasOOM = false
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
                message: wasOOM
                    ? "Container VM ran out of memory; restart failed, retrying…"
                    : "Container runtime restart failed; retrying…",
                reason: wasOOM ? "oom" : "restart_failed",
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
        let cachePressureWarning = await maintenance?.snapshot().cachePressureWarning
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
            bootId: bootId,
            lastIncident: lastIncident,
            cachePressureWarning: cachePressureWarning
        )
        do {
            try await statusStore.publish(snapshot)
        } catch {
            log("Could not publish container runtime status: " + error.localizedDescription)
        }
        await onStatusChanged(snapshot)
    }
}
