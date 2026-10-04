import Foundation

/// Runtime maintenance policy and the launcher-managed cleanup schedule.
/// Docker itself performs log rotation and build-cache garbage collection.
actor ContainerRuntimeMaintenance {
    struct StepResult: Codable, Equatable, Sendable {
        let name: String
        let reclaimedBytes: UInt64?
        let error: String?
    }

    struct Snapshot: Encodable, Sendable {
        let running: Bool
        let lastAttemptAt: Date?
        let completedAt: Date?
        let nextRunAt: Date?
        let results: [StepResult]
        let imageMinimumAgeHours = 32
        let intervalHours = 4
        let buildCacheLimit = ContainerRuntimeMaintenance.buildCacheMaximum
    }

    static let loggingDriver = "local"
    static let loggingOptions = ["max-size": "10m", "max-file": "3"]
    static let buildCacheMaximum = "5GB"
    static let buildCacheReserve = "1GB"
    static let cleanupInterval: TimeInterval = 4 * 60 * 60
    static let cleanupSteps: [(name: String, command: [String])] = [
        ("Unused image cleanup", [
            "docker", "image", "prune", "--all", "--force", "--filter", "until=32h",
        ]),
        ("Build cache cleanup", [
            "docker", "buildx", "prune", "--builder", "default", "--all", "--force",
            "--max-used-space", buildCacheMaximum, "--reserved-space", buildCacheReserve,
        ]),
    ]

    typealias Execute = @Sendable ([String]) async throws -> SmolVMCommandResult
    typealias Log = @Sendable (String) -> Void

    private struct Record: Codable {
        let lastImagePruneAttemptAt: Date
        var completedAt: Date?
        var results: [StepResult]?
    }

    private let stateURL: URL
    private let execute: Execute
    private let now: @Sendable () -> Date
    private let log: Log
    private var didLoadRecord = false
    private var lastImagePruneAttemptAt: Date?
    private var completedAt: Date?
    private var results: [StepResult] = []
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
    func reconcile(force: Bool = false) -> Task<Void, Never>? {
        guard !isPausing, !Task.isCancelled else { return nil }
        if let cleanupTask { return force ? cleanupTask : nil }
        loadRecordIfNeeded()
        if !force, let lastImagePruneAttemptAt,
           now().timeIntervalSince(lastImagePruneAttemptAt) < Self.cleanupInterval {
            return nil
        }
        completedAt = nil
        results = []
        lastImagePruneAttemptAt = now()
        saveRecord()
        let task = Task { await runCleanup() }
        cleanupTask = task
        return task
    }

    func snapshot() -> Snapshot {
        loadRecordIfNeeded()
        return Snapshot(
            running: cleanupTask != nil, lastAttemptAt: lastImagePruneAttemptAt,
            completedAt: completedAt,
            nextRunAt: lastImagePruneAttemptAt?.addingTimeInterval(Self.cleanupInterval),
            results: results
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
        } catch CocoaError.fileReadNoSuchFile {
            // The first healthy startup is the first cleanup attempt.
        } catch {
            log("Could not read runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func saveRecord() {
        guard let lastImagePruneAttemptAt else { return }
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
                completedAt: completedAt, results: results
            ))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log("Could not save runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func runCleanup() async {
        defer { cleanupTask = nil }
        guard !Task.isCancelled else { return }
        for step in Self.cleanupSteps {
            do {
                try Task.checkCancellation()
                let result = try await execute(step.command)
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
                results.append(StepResult(name: step.name,
                                          reclaimedBytes: reclaimed.flatMap { Self.reclaimedBytes($0) },
                                          error: nil))
                log(step.name + " completed" + (reclaimed.map { ": \($0)" } ?? ""))
            } catch is CancellationError {
                // Runtime shutdown or recovery owns cancellation.
                return
            } catch {
                results.append(StepResult(name: step.name, reclaimedBytes: nil, error: error.localizedDescription))
                log(step.name + " failed: " + error.localizedDescription)
            }
            saveRecord()
        }
        completedAt = now()
        saveRecord()
        await VMResourceSampler.invalidateDiskSamples()
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
