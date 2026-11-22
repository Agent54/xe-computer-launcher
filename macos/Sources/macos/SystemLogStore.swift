import Foundation

/// Thread-safe recent logs with batched, bounded history on disk.
final class SystemLogStore: @unchecked Sendable {
    struct Entry: Codable, Sendable, Equatable {
        let id: UInt64
        let source: String
        let line: String
        let timestamp: Date

        private let recordedSeverity: SystemLogSeverity?
        var severity: SystemLogSeverity { recordedSeverity ?? .classify(source: source, line: line) }

        init(id: UInt64, source: String, line: String, timestamp: Date) {
            self.init(id: id, source: source, line: line, timestamp: timestamp,
                      severity: .classify(source: source, line: line))
        }

        fileprivate init(id: UInt64, source: String, line: String, timestamp: Date, severity: SystemLogSeverity) {
            self.id = id
            self.source = source
            self.line = line
            self.timestamp = timestamp
            recordedSeverity = severity
        }

        func cachingSeverity() -> Self {
            guard recordedSeverity == nil else { return self }
            return Self(id: id, source: source, line: line, timestamp: timestamp, severity: severity)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.source == rhs.source && lhs.line == rhs.line && lhs.timestamp == rhs.timestamp
        }
    }

    struct Snapshot: Sendable {
        let revision: UInt64
        let entries: [Entry]
    }

    struct History: Sendable {
        let entries: [Entry]
        let hasEarlier: Bool
    }

    struct Configuration: Sendable {
        var memoryEntries = 10_000
        var fileBytes = 5 * 1024 * 1024
        var fileCount = 4
        var flushDelay: TimeInterval = 0.5
    }

    let directoryURL: URL
    private let configuration: Configuration
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.xe.computer.system-logs", qos: .utility)
    private var entries: [Entry?]
    private var start = 0
    private var count = 0
    private var nextID: UInt64
    private var revision: UInt64 = 0
    private var pending: [Entry] = []
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var flushScheduled = false
    private var reportedWriteFailure = false
    private var errorEntry: Entry?
    private var lastErrorInRun: Entry?
    private var persistedErrorID: UInt64?
    // File state is confined to writer.
    private var handle: FileHandle?
    private var fileBytes = 0

    init(directoryURL: URL, configuration: Configuration = Configuration()) {
        precondition(configuration.memoryEntries > 0 && configuration.fileBytes > 0 && configuration.fileCount > 0)
        self.directoryURL = directoryURL
        self.configuration = configuration
        entries = Array(repeating: nil, count: configuration.memoryEntries)
        let savedIssue = (try? Data(contentsOf: directoryURL.appendingPathComponent("last-warning.json")))
            .flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        errorEntry = savedIssue.flatMap { $0.id < UInt64(Int64.max) && $0.severity == .error ? $0 : nil }
        persistedErrorID = errorEntry?.id
        // Read only the journal tail at startup; older history is loaded on demand.
        let latest = (0..<configuration.fileCount).lazy.compactMap { index in
            Self.readEntries(url: directoryURL.appendingPathComponent(index == 0 ? "system.jsonl" : "system.jsonl.\(index)"), limit: 1).first?.id
        }.first ?? 0
        nextID = max(latest, savedIssue.flatMap { $0.id < UInt64(Int64.max) ? $0.id : nil } ?? 0) + 1
        // Keep the recent journal tail ready for the first open, including after a relaunch.
        writer.async { [weak self] in self?.warmRecentEntries() }
        // Import a previous crash from older log files without delaying startup.
        // Afterwards the small summary file preserves it even after log rotation.
        if errorEntry == nil { writer.async { [weak self] in self?.restoreLatestError() } }
    }

    var latestError: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return errorEntry
    }

    func append(_ source: String, _ line: String, timestamp: Date = Date()) {
        let boundedLine = line.utf8.count > 32_768
            ? String(decoding: line.utf8.prefix(32_768), as: UTF8.self) + "… [truncated]" : line
        let source = String(source.prefix(64))
        let severity = SystemLogSeverity.classify(source: source, line: boundedLine)
        lock.lock()
        let entry = Entry(id: nextID, source: source, line: boundedLine, timestamp: timestamp, severity: severity)
        nextID += 1
        insert(entry)
        recordError(entry)
        pending.append(entry)
        let schedule = !flushScheduled
        flushScheduled = true
        let listeners = observers.values
        lock.unlock()
        for listener in listeners { listener.yield(()) }
        if schedule {
            writer.asyncAfter(deadline: .now() + configuration.flushDelay) { [weak self] in self?.flushPending() }
        }
    }

    func updates() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        lock.withLock { observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.removeObserver(id) }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: id) }
    }

    /// A bounded tail from memory. The cursor advances over hidden entries too.
    func recentPage(after: UInt64 = 0, limit: Int, sources: Set<String>?,
                    minimumSeverity: SystemLogSeverity) -> (page: History, cursor: UInt64) {
        lock.withLock {
            var result: [Entry] = []
            var remainingBytes = 64 * 1024
            let cursor = max(after, nextID - 1)
            for offset in (0..<count).reversed() {
                guard let entry = entries[(start + offset) % entries.count], entry.id > after else { break }
                guard sources?.contains(entry.source) ?? true, entry.severity.rawValue >= minimumSeverity.rawValue else { continue }
                remainingBytes -= entry.line.utf8.count + 100
                if result.count >= limit || (remainingBytes < 0 && !result.isEmpty) {
                    return (History(entries: result.reversed(), hasEarlier: true), cursor)
                }
                result.append(entry)
            }
            return (History(entries: result.reversed(), hasEarlier: false), cursor)
        }
    }

    private func warmRecentEntries() {
        let limit = min(1_000, configuration.memoryEntries)
        var journal: [Entry] = []
        for index in 0..<configuration.fileCount {
            journal += Self.readEntries(url: fileURL(index), limit: limit - journal.count)
            if journal.count == limit { break }
        }
        let older = journal.reversed()
        guard !older.isEmpty else { return }
        let listeners = lock.withLock {
            let live = (0..<count).compactMap { entries[(start + $0) % entries.count] }
            let combined = (older + live).suffix(entries.count)
            for (index, entry) in combined.enumerated() { entries[index] = entry }
            start = 0
            count = combined.count
            revision += 1
            return observers.values
        }
        for listener in listeners { listener.yield(()) }
    }

    func snapshot(sources: Set<String>? = nil, minimumSeverity: SystemLogSeverity = .info, after: UInt64 = 0) -> Snapshot {
        lock.lock()
        let revision = revision
        let recent = (0..<count).compactMap { index -> Entry? in
            guard let entry = entries[(start + index) % entries.count], entry.id > after else { return nil }
            return entry
        }
        lock.unlock()
        if sources == nil, minimumSeverity == .info { return Snapshot(revision: revision, entries: recent) }
        return Snapshot(revision: revision, entries: recent.filter {
            (sources?.contains($0.source) ?? true) && (minimumSeverity == .info || $0.severity.rawValue >= minimumSeverity.rawValue)
        })
    }

    func history(before: UInt64? = nil, limit: Int = 10_000, sources: Set<String>? = nil,
                 minimumSeverity: SystemLogSeverity = .info) async -> History {
        let (files, retainedError) = await withCheckedContinuation { continuation in
            writer.async {
                self.flushPending()
                // Opening handles on the writer queue keeps each page consistent across
                // rotation. Reading the captured byte ranges doesn't hold up the writer.
                let files = (0..<self.configuration.fileCount).compactMap { index -> JournalFile? in
                    guard let handle = try? FileHandle(forReadingFrom: self.fileURL(index)),
                          let length = try? handle.seekToEnd() else { return nil }
                    return JournalFile(handle: handle, length: length)
                }
                continuation.resume(returning: (files, self.latestError))
            }
        }
        let read = Task.detached(priority: .userInitiated) {
            defer { for file in files { try? file.handle.close() } }
            var result: [Entry] = []
            for file in files {
                if Task.isCancelled { return History(entries: [], hasEarlier: false) }
                result += Self.readEntries(file: file, before: before,
                    limit: limit + 1 - result.count, sources: sources, minimumSeverity: minimumSeverity)
                if result.count > limit { break }
            }
            // The error behind the tray notice can outlive the journal's rotation.
            if minimumSeverity != .info, let error = retainedError,
               before.map({ error.id < $0 }) ?? true, sources?.contains(error.source) ?? true,
               !result.contains(where: { $0.id == error.id }) {
                let index = result.firstIndex { $0.id < error.id } ?? result.endIndex
                result.insert(error, at: index)
            }
            return History(entries: Array(result.prefix(limit).reversed()), hasEarlier: result.count > limit)
        }
        return await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            writer.async {
                self.flushPending()
                continuation.resume()
            }
        }
    }

    private func insert(_ entry: Entry) {
        let index = (start + count) % entries.count
        entries[index] = entry
        if count == entries.count { start = (start + 1) % entries.count } else { count += 1 }
        revision += 1
    }

    /// Called with the lock held. Identical repeated errors share one notice
    /// during this run; a new error or a recurrence after relaunch can notify again.
    private func recordError(_ entry: Entry) {
        guard entry.severity == .error else { return }
        if lastErrorInRun?.source == entry.source, lastErrorInRun?.line == entry.line { return }
        lastErrorInRun = entry
        errorEntry = entry
    }

    private func restoreLatestError() {
        let previous = (0..<configuration.fileCount).lazy.compactMap {
            Self.readEntries(url: self.fileURL($0), limit: 1, minimumSeverity: .error).first
        }.first
        lock.lock()
        if let previous, previous.id > (errorEntry?.id ?? 0) {
            errorEntry = previous
            revision += 1
        }
        lock.unlock()
        try? persistError()
    }

    private func persistError() throws {
        guard let error = latestError, error.id != persistedErrorID else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directoryURL.appendingPathComponent("last-warning.json")
        try JSONEncoder().encode(error).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        persistedErrorID = error.id
    }

    private func fileURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent(index == 0 ? "system.jsonl" : "system.jsonl.\(index)")
    }

    private func flushPending() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }
        do {
            try openIfNeeded()
            var chunk = Data()
            let encoder = JSONEncoder()
            for entry in batch {
                var data = try encoder.encode(entry)
                data.append(0x0a)
                if fileBytes + chunk.count > 0 && fileBytes + chunk.count + data.count > configuration.fileBytes {
                    try write(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    try rotate()
                    try openIfNeeded()
                }
                chunk.append(data)
            }
            try write(chunk)
            try persistError()
        } catch {
            try? handle?.close()
            handle = nil
            lock.lock()
            let notify = !reportedWriteFailure
            if notify {
                let entry = Entry(id: nextID, source: "launcher", line: "Could not save System Logs: \(error.localizedDescription)", timestamp: Date())
                insert(entry)
                recordError(entry)
                nextID += 1
                reportedWriteFailure = true
            }
            let listeners = observers.values
            lock.unlock()
            if notify { for listener in listeners { listener.yield(()) } }
        }
    }

    private func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        fileBytes += data.count
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = fileURL(0)
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: file)
        fileBytes = Int(try opened.seekToEnd())
        // Separate a partial last record from the next complete JSON record after a crash.
        if fileBytes > 0, let reader = try? FileHandle(forReadingFrom: file) {
            defer { try? reader.close() }
            try reader.seek(toOffset: UInt64(fileBytes - 1))
            if try reader.read(upToCount: 1)?.first != 0x0a {
                try opened.write(contentsOf: Data([0x0a]))
                fileBytes += 1
            }
        }
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        let oldest = fileURL(configuration.fileCount - 1)
        if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
        if configuration.fileCount > 1 {
            for index in stride(from: configuration.fileCount - 2, through: 0, by: -1) {
                let file = fileURL(index)
                if fm.fileExists(atPath: file.path) { try fm.moveItem(at: file, to: fileURL(index + 1)) }
            }
        }
    }

    /// Scan backwards in small blocks and stop once the requested page is filled.
    private static func readEntries(url: URL, before: UInt64? = nil, limit: Int, sources: Set<String>? = nil,
                                    minimumSeverity: SystemLogSeverity = .info) -> [Entry] {
        guard limit > 0, let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return [] }
        return readEntries(file: JournalFile(handle: file, length: length), before: before, limit: limit,
                           sources: sources, minimumSeverity: minimumSeverity)
    }

    private struct JournalFile: Sendable {
        let handle: FileHandle
        let length: UInt64
    }

    private static func readEntries(file: JournalFile, before: UInt64?, limit: Int, sources: Set<String>?,
                                    minimumSeverity: SystemLogSeverity) -> [Entry] {
        guard limit > 0 else { return [] }
        do {
            var position = file.length
            var remainder = Data()
            var result: [Entry] = []
            let decoder = JSONDecoder()
            while position > 0 {
                if Task.isCancelled { break }
                let size = min(position, 65_536)
                position -= size
                try file.handle.seek(toOffset: position)
                var data = try file.handle.read(upToCount: Int(size)) ?? Data()
                data.append(remainder)
                let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
                remainder = position == 0 ? Data() : Data(lines[0])
                for line in lines.dropFirst(position == 0 ? 0 : 1).reversed() {
                    guard let entry = try? decoder.decode(Entry.self, from: Data(line)), entry.id < UInt64(Int64.max),
                          before == nil || entry.id < before!,
                          sources == nil || sources!.contains(entry.source) else { continue }
                    let cached = entry.cachingSeverity()
                    guard cached.severity.rawValue >= minimumSeverity.rawValue else { continue }
                    result.append(cached)
                    if result.count == limit { return result }
                }
                // A malformed, unterminated record must not grow memory without bound.
                if remainder.count > 262_144 { remainder.removeAll() }
            }
            return result
        } catch { return [] }
    }
}
