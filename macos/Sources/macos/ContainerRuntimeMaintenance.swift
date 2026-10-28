import Foundation

/// Runtime maintenance policy and the launcher-managed cleanup schedule.
/// Docker performs log rotation; the launcher owns build-cache collection.
actor ContainerRuntimeMaintenance {
    struct StepResult: Codable, Equatable, Sendable {
        let name: String
        let reclaimedBytes: UInt64?
        let error: String?
    }

    struct CachePressureWarning: Codable, Equatable, Sendable {
        let id: String
        let message: String
        let occurredAt: Date
    }

    struct Snapshot: Encodable, Sendable {
        let running: Bool
        let lastAttemptAt: Date?
        let completedAt: Date?
        let nextRunAt: Date?
        let results: [StepResult]
        let cachePressureWarning: CachePressureWarning?
        let imageMinimumAgeHours = 32
        let intervalHours = 4
        let buildCacheMinimumAgeHours = ContainerRuntimeMaintenance.buildCacheMinimumAgeHours
        let buildCacheMinimumFreeDiskPercent = ContainerRuntimeMaintenance.buildCacheMinimumFreeDiskPercent
    }

    static let loggingDriver = "local"
    static let loggingOptions = ["max-size": "10m", "max-file": "3"]
    static let buildCacheMinimumAgeHours = 32
    // Try older unused cache first, checking cheap filesystem counters between passes.
    static let buildCachePressureAgeHours = [8, 1, 0]
    static let buildCacheMinimumFreeDiskPercent = 5
    static let emergencyFreeDiskPercent = 2
    static let runningBuildsCommand = [
        "docker", "buildx", "history", "ls", "--builder", "default",
        "--filter", "status=running", "--format", "{{.Ref}}",
    ]
    static let cleanupInterval: TimeInterval = 4 * 60 * 60
    static let pressureRetryInterval: TimeInterval = 60

    private enum CleanupStep: CaseIterable {
        case images, buildCache

        var name: String {
            switch self {
            case .images: "Unused image cleanup"
            case .buildCache: "Build cache cleanup"
            }
        }
    }

    static func buildCacheMinimumFreeBytes(
        diskTotalBytes: UInt64, percent: Int = buildCacheMinimumFreeDiskPercent
    ) -> UInt64 {
        let percent = UInt64(percent)
        // Round up without multiplying the full capacity, which could overflow.
        return diskTotalBytes / 100 * percent
            + (diskTotalBytes % 100 * percent + 99) / 100
    }

    static func buildCachePruneCommand(minimumAgeHours: Int = buildCacheMinimumAgeHours) -> [String] {
        // Any nonzero space budget makes Docker 28 size *all* cache records in
        // parallel before filtering. Age-only pruning sizes deletions sequentially.
        return [
            "docker", "buildx", "prune", "--builder", "default", "--all", "--force",
            "--filter", "until=\(minimumAgeHours)h",
        ]
    }

    typealias Execute = @Sendable ([String]) async throws -> SmolVMCommandResult
    typealias Log = @Sendable (String) -> Void

    private struct Record: Codable {
        let lastImagePruneAttemptAt: Date?
        var completedAt: Date?
        var results: [StepResult]?
        var cachePressureWarning: CachePressureWarning?
        var diskPressureActive: Bool?
    }

    private let stateURL: URL
    private let execute: Execute
    private let now: @Sendable () -> Date
    private let log: Log
    private var didLoadRecord = false
    private var lastImagePruneAttemptAt: Date?
    private var completedAt: Date?
    private var results: [StepResult] = []
    private var cachePressureWarning: CachePressureWarning?
    private var diskPressureActive = false
    private var lastPressureCheckAt: Date?
    private var cleanupTask: Task<Void, Never>?
    private var isPausing = false

    init(
        stateURL: URL,
        execute: @escaping Execute,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping Log
    ) {
        self.stateURL = stateURL
        self.execute = execute
        self.now = now
        self.log = log
    }

    /// Called only while Docker is healthy. Scheduling does not block its health checks.
    @discardableResult
    func reconcile(force: Bool = false, resources: VMResourceSnapshot? = nil) -> Task<Void, Never>? {
        guard !isPausing, !Task.isCancelled else { return nil }
        loadRecordIfNeeded()
        var emergency = false
        if let total = resources?.diskTotalBytes, total > 0,
           let available = resources?.diskAvailableBytes, available <= total {
            observeDiskPressure(available < Self.buildCacheMinimumFreeBytes(diskTotalBytes: total))
            emergency = available < Self.buildCacheMinimumFreeBytes(
                diskTotalBytes: total, percent: Self.emergencyFreeDiskPercent
            )
        }
        if let cleanupTask { return force ? cleanupTask : nil }
        var requiresIdleBuilder = false
        if !force, let lastImagePruneAttemptAt {
            if now().timeIntervalSince(lastImagePruneAttemptAt) < Self.cleanupInterval {
                guard emergency,
                      now().timeIntervalSince(lastPressureCheckAt ?? lastImagePruneAttemptAt)
                        >= Self.pressureRetryInterval else { return nil }
                requiresIdleBuilder = true
                lastPressureCheckAt = now()
            }
        }
        let task = Task { await runCleanup(requiresIdleBuilder: requiresIdleBuilder) }
        cleanupTask = task
        return task
    }

    func snapshot() -> Snapshot {
        loadRecordIfNeeded()
        return Snapshot(
            running: cleanupTask != nil, lastAttemptAt: lastImagePruneAttemptAt,
            completedAt: completedAt,
            nextRunAt: lastImagePruneAttemptAt?.addingTimeInterval(Self.cleanupInterval),
            results: results, cachePressureWarning: cachePressureWarning
        )
    }

    /// Finish cancelling the guest command before the supervisor stops or restarts the VM.
    func pause() async {
        isPausing = true
        let running = cleanupTask
        running?.cancel()
        await running?.value
        isPausing = false
    }

    private func loadRecordIfNeeded() {
        guard !didLoadRecord else { return }
        didLoadRecord = true
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(Record.self, from: Data(contentsOf: stateURL))
            lastImagePruneAttemptAt = record.lastImagePruneAttemptAt
            completedAt = record.completedAt
            results = record.results ?? []
            cachePressureWarning = record.cachePressureWarning
            diskPressureActive = record.diskPressureActive ?? false
        } catch CocoaError.fileReadNoSuchFile {
            // The first healthy startup is the first cleanup attempt.
        } catch {
            log("Could not read runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func saveRecord() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Record(
                lastImagePruneAttemptAt: lastImagePruneAttemptAt,
                completedAt: completedAt, results: results, cachePressureWarning: cachePressureWarning,
                diskPressureActive: diskPressureActive
            ))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log("Could not save runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func runCleanup(requiresIdleBuilder: Bool) async {
        defer { cleanupTask = nil }
        guard !Task.isCancelled else { return }
        if requiresIdleBuilder {
            do {
                // Check activity before any pruning; unknown activity defers the early run.
                let activity = try await execute(Self.runningBuildsCommand)
                try Task.checkCancellation()
                guard activity.exitCode == 0,
                      activity.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    log("Emergency cleanup deferred: a build is running or build activity is unavailable")
                    return
                }
                guard try await diskIsUnderPressure(percent: Self.emergencyFreeDiskPercent) else { return }
            } catch is CancellationError {
                return
            } catch {
                log("Emergency cleanup deferred: " + error.localizedDescription)
                return
            }
        }
        completedAt = nil
        results = []
        lastImagePruneAttemptAt = now()
        lastPressureCheckAt = lastImagePruneAttemptAt
        saveRecord()
        for step in CleanupStep.allCases {
            var resultName = step.name
            do {
                try Task.checkCancellation()
                let command: [String]
                switch step {
                case .images:
                    command = ["docker", "image", "prune", "--all", "--force", "--filter", "until=32h"]
                case .buildCache:
                    command = Self.buildCachePruneCommand()
                }
                try await runPrune(name: step.name, command: command)
                if step == .buildCache {
                    resultName = "Low disk space cleanup"
                    try await cleanUnderDiskPressure()
                }
            } catch is CancellationError {
                // Runtime shutdown or recovery owns cancellation.
                return
            } catch {
                results.append(StepResult(name: resultName, reclaimedBytes: nil, error: error.localizedDescription))
                log(resultName + " failed: " + error.localizedDescription)
            }
            saveRecord()
        }
        completedAt = now()
        saveRecord()
        await VMResourceSampler.invalidateDiskSamples()
    }

    private func runPrune(name: String, command: [String]) async throws {
        try Task.checkCancellation()
        let result = try await execute(command)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            throw NSError(domain: "RuntimeMaintenance", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: result.standardError.isEmpty
                    ? "Docker exited with code \(result.exitCode)" : result.standardError,
            ])
        }
        let reclaimed = result.standardOutput.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { $0.hasPrefix("Total reclaimed space:") || $0.hasPrefix("Total:") }
        results.append(StepResult(name: name,
                                  reclaimedBytes: reclaimed.flatMap { Self.reclaimedBytes($0) }, error: nil))
        log(name + " completed" + (reclaimed.map { ": \($0)" } ?? ""))
        saveRecord()
    }

    private func diskIsUnderPressure(percent: Int = buildCacheMinimumFreeDiskPercent) async throws -> Bool {
        try Task.checkCancellation()
        let status = try await execute(VMResourceSampler.guestDiskStatusCommand)
        try Task.checkCancellation()
        guard status.exitCode == 0,
              let disk = VMResourceSampler.parseGuestDiskStatus(status.standardOutput) else {
            throw NSError(domain: "RuntimeMaintenance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not read Docker filesystem capacity; skipped cleanup of younger cache.",
            ])
        }
        observeDiskPressure(disk.availableBytes < Self.buildCacheMinimumFreeBytes(diskTotalBytes: disk.totalBytes))
        return disk.availableBytes < Self.buildCacheMinimumFreeBytes(diskTotalBytes: disk.totalBytes, percent: percent)
    }

    private func observeDiskPressure(_ underPressure: Bool) {
        guard diskPressureActive != underPressure else { return }
        diskPressureActive = underPressure
        if underPressure {
            let warning = CachePressureWarning(
                id: UUID().uuidString,
                message: "VM free disk space fell below 5%. The next scheduled cleanup may include unused build cache younger than 32 hours if space is still low. Early cleanup only starts below 2% free space when no build is running. Future builds may need to rebuild removed layers. Increase the VM disk size in Xe Launcher to avoid this.",
                occurredAt: now()
            )
            cachePressureWarning = warning
            log("Warning: " + warning.message)
        }
        saveRecord()
    }

    private func cleanUnderDiskPressure() async throws {
        for age in Self.buildCachePressureAgeHours {
            guard try await diskIsUnderPressure() else { return }
            let name = age == 0 ? "Unused build cache cleanup (low disk space)"
                : "Build cache older than \(age) hours cleanup (low disk space)"
            try await runPrune(name: name, command: Self.buildCachePruneCommand(minimumAgeHours: age))
        }
        if try await diskIsUnderPressure() {
            throw NSError(domain: "RuntimeMaintenance", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Less than 5% disk space remains after unused cache cleanup. Increase the VM disk size or remove unneeded images and volumes.",
            ])
        }
    }

    static func reclaimedBytes(_ line: String) -> UInt64? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = ["Total reclaimed space:", "Total:"].first(where: { line.hasPrefix($0) }) else {
            return nil
        }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let number = value.prefix { $0.isNumber || $0 == "." }
        let unit = value.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
        let factors: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                        "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824]
        guard let amount = Double(number), let factor = factors[unit], amount.isFinite,
              amount >= 0, amount * factor < Double(UInt64.max) else { return nil }
        return UInt64(amount * factor)
    }
}
