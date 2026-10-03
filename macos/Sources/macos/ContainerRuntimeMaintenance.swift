import Foundation

/// Runtime maintenance policy and the launcher-managed cleanup schedule.
/// Docker itself performs log rotation and build-cache garbage collection.
actor ContainerRuntimeMaintenance {
    static let loggingDriver = "local"
    static let loggingOptions = ["max-size": "10m", "max-file": "3"]
    static let buildCacheMaximum = "5GB"
    static let buildCacheReserve = "1GB"
    static let imagePruneInterval: TimeInterval = 4 * 60 * 60
    static let imagePruneSteps: [(name: String, command: [String])] = [
        ("Unused image cleanup", [
            "docker", "image", "prune", "--all", "--force", "--filter", "until=32h",
        ]),
    ]

    typealias Execute = @Sendable ([String]) async throws -> SmolVMCommandResult
    typealias Log = @Sendable (String) -> Void

    private struct Record: Codable {
        let lastImagePruneAttemptAt: Date
    }

    private let stateURL: URL
    private let execute: Execute
    private let now: @Sendable () -> Date
    private let log: Log
    private var didLoadRecord = false
    private var lastImagePruneAttemptAt: Date?
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
    func reconcile() -> Task<Void, Never>? {
        guard !isPausing, cleanupTask == nil, !Task.isCancelled else { return nil }
        loadRecordIfNeeded()
        if let lastImagePruneAttemptAt,
           now().timeIntervalSince(lastImagePruneAttemptAt) < Self.imagePruneInterval {
            return nil
        }
        let task = Task { await pruneImages() }
        cleanupTask = task
        return task
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
        } catch CocoaError.fileReadNoSuchFile {
            // The first healthy startup is the first cleanup attempt.
        } catch {
            log("Could not read runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func saveAttempt(at date: Date) {
        lastImagePruneAttemptAt = date
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Record(lastImagePruneAttemptAt: date))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            log("Could not save runtime maintenance state: " + error.localizedDescription)
        }
    }

    private func pruneImages() async {
        defer { cleanupTask = nil }
        guard !Task.isCancelled else { return }
        // Persist attempts, including failures, to avoid retrying on every health check.
        saveAttempt(at: now())
        for step in Self.imagePruneSteps {
            do {
                try Task.checkCancellation()
                let result = try await execute(step.command)
                try Task.checkCancellation()
                let reclaimed = result.standardOutput.split(separator: "\n")
                    .last { $0.hasPrefix("Total reclaimed space:") }
                log(step.name + " completed" + (reclaimed.map { ": \($0)" } ?? ""))
            } catch is CancellationError {
                // Runtime shutdown or recovery owns cancellation.
                return
            } catch {
                log(step.name + " failed: " + error.localizedDescription)
            }
        }
    }
}
