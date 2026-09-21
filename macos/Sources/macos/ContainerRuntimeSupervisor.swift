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
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias StatusChanged = @Sendable (ContainerRuntimeSnapshot) -> Void
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
    private let sleep: Sleep
    private let now: @Sendable () -> Date
    private let onStatusChanged: StatusChanged
    private let log: Log

    private var state = State.idle
    private var consecutiveFailures = 0
    private var recoveryDates: [Date] = []
    private var lastDiagnosticsAt = Date.distantPast
    private var lastDiagnostics: SmolVMMachine?

    init(
        configuration: Configuration = Configuration(),
        statusStore: ContainerRuntimeStatusStore = ContainerRuntimeStatusStore(),
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
        readHostResources: @escaping ReadHostResources = { HostResourceSampler.shared.snapshot() },
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
        self.sleep = sleep
        self.now = now
        self.onStatusChanged = onStatusChanged
        self.log = log
    }

    @discardableResult
    func start() async throws -> SmolVMStartupResult {
        state = .starting
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
            await publish(
                phase: .failed,
                message: "Container runtime failed to start",
                reason: "startup_failure"
            )
            throw error
        }
    }

    func reconcile() async {
        guard state != .idle, state != .starting, state != .recovering,
              state != .failed, state != .stopped else { return }

        if await probeDocker() {
            consecutiveFailures = 0
            if state == .degraded {
                state = .healthy
                await publish(
                    phase: .healthy,
                    message: "Container runtime ready",
                    memory: lastDiagnostics?.memory
                )
                log("Container runtime recovered without a restart")
            }
            await refreshDiagnosticsIfNeeded()
            return
        }

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
        try await stopMachine()
        await publish(phase: .stopped, message: "Container runtime stopped")
    }

    func snapshot() async -> ContainerRuntimeSnapshot {
        await statusStore.snapshot()
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

        let cutoff = now().addingTimeInterval(-configuration.recoveryWindow)
        recoveryDates.removeAll { $0 < cutoff }
        guard recoveryDates.count < configuration.maximumRecoveries else {
            state = .failed
            let message = "Container runtime recovery stopped after repeated failures"
            await publish(
                phase: .failed,
                message: message,
                reason: "recovery_exhausted",
                memory: diagnosed?.memory
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
            memory: diagnosed?.memory
        )
        log(message)

        await resetRouter()
        await publish(
            phase: .restarting,
            message: message,
            reason: wasOOM ? "oom" : "docker_unavailable",
            recoveryAttempt: attempt,
            memory: diagnosed?.memory
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
        let snapshot = ContainerRuntimeSnapshot(
            phase: phase,
            message: message,
            reason: reason,
            updatedAt: now(),
            recoveryAttempt: recoveryAttempt,
            memoryTotalBytes: memory?.totalBytes,
            memoryAvailableBytes: memory?.availableBytes,
            oomKillCount: memory?.oomKillCount,
            hostResources: hostResources
        )
        do {
            try await statusStore.publish(snapshot)
        } catch {
            log("Could not publish container runtime status: " + error.localizedDescription)
        }
        onStatusChanged(snapshot)
    }
}
