import Foundation

/// Thread-safe recent logs with batched, bounded history on disk.
final class SystemLogStore: @unchecked Sendable {
    struct Entry: Codable, Sendable, Equatable {
        let id: UInt64
        let source: String
        let line: String
        let timestamp: Date
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
    private var pending: [Data] = []
    private var flushScheduled = false
    private var reportedWriteFailure = false
    // File state is confined to writer.
    private var handle: FileHandle?
    private var fileBytes = 0

    init(directoryURL: URL, configuration: Configuration = Configuration()) {
        precondition(configuration.memoryEntries > 0 && configuration.fileBytes > 0 && configuration.fileCount > 0)
        self.directoryURL = directoryURL
        self.configuration = configuration
        entries = Array(repeating: nil, count: configuration.memoryEntries)
        // Read only the journal tail at startup; older history is loaded on demand.
        let latest = (0..<configuration.fileCount).lazy.compactMap { index in
            Self.readEntries(url: directoryURL.appendingPathComponent(index == 0 ? "system.jsonl" : "system.jsonl.\(index)"), limit: 1).first?.id
        }.first ?? 0
        nextID = latest + 1
    }

    func append(_ source: String, _ line: String, timestamp: Date = Date()) {
        let boundedLine = line.utf8.count > 32_768
            ? String(decoding: line.utf8.prefix(32_768), as: UTF8.self) + "… [truncated]" : line
        lock.lock()
        let entry = Entry(id: nextID, source: String(source.prefix(64)), line: boundedLine, timestamp: timestamp)
        nextID += 1
        insert(entry)
        if var data = try? JSONEncoder().encode(entry) {
            data.append(0x0a)
            pending.append(data)
        }
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule {
            writer.asyncAfter(deadline: .now() + configuration.flushDelay) { [weak self] in self?.flushPending() }
        }
    }

    func snapshot(sources: Set<String>? = nil) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let recent = (0..<count).compactMap { entries[(start + $0) % entries.count] }
        return Snapshot(revision: revision, entries: sources.map { selected in recent.filter { selected.contains($0.source) } } ?? recent)
    }

    func history(before: UInt64? = nil, limit: Int = 10_000, sources: Set<String>? = nil) async -> History {
        await withCheckedContinuation { continuation in
            writer.async {
                self.flushPending()
                var result: [Entry] = []
                for index in 0..<self.configuration.fileCount {
                    result += Self.readEntries(url: self.fileURL(index), before: before, limit: limit + 1 - result.count, sources: sources)
                    if result.count > limit { break }
                }
                continuation.resume(returning: History(entries: Array(result.prefix(limit).reversed()), hasEarlier: result.count > limit))
            }
        }
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
            for data in batch {
                if fileBytes + chunk.count > 0 && fileBytes + chunk.count + data.count > configuration.fileBytes {
                    try write(chunk)
                    chunk.removeAll(keepingCapacity: true)
                    try rotate()
                    try openIfNeeded()
                }
                chunk.append(data)
            }
            try write(chunk)
        } catch {
            try? handle?.close()
            handle = nil
            lock.lock()
            if !reportedWriteFailure {
                insert(Entry(id: nextID, source: "launcher", line: "Could not save System Logs: \(error.localizedDescription)", timestamp: Date()))
                nextID += 1
                reportedWriteFailure = true
            }
            lock.unlock()
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
    private static func readEntries(url: URL, before: UInt64? = nil, limit: Int, sources: Set<String>? = nil) -> [Entry] {
        guard limit > 0, let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        do {
            var position = try file.seekToEnd()
            var remainder = Data()
            var result: [Entry] = []
            let decoder = JSONDecoder()
            while position > 0 {
                let size = min(position, 65_536)
                position -= size
                try file.seek(toOffset: position)
                var data = try file.read(upToCount: Int(size)) ?? Data()
                data.append(remainder)
                let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
                remainder = position == 0 ? Data() : Data(lines[0])
                for line in lines.dropFirst(position == 0 ? 0 : 1).reversed() {
                    guard let entry = try? decoder.decode(Entry.self, from: Data(line)), entry.id < UInt64(Int64.max),
                          before == nil || entry.id < before!,
                          sources == nil || sources!.contains(entry.source) else { continue }
                    result.append(entry)
                    if result.count == limit { return result }
                }
                // A malformed, unterminated record must not grow memory without bound.
                if remainder.count > 262_144 { remainder.removeAll() }
            }
            return result
        } catch { return [] }
    }
}
