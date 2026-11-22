import Foundation

/// Reads only new bytes from SmolVM's existing host console files.
actor RuntimeLogCollector {
    static let shared = RuntimeLogCollector()
    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var partial = Data()
        var tail = Data()
        var modifiedAt: Date?
    }

    private let directoryURL: URL
    private let log: @Sendable (String, String) -> Void
    private var cursors: [String: Cursor] = [:]
    private var lastFailure: String?
    private var isStarting = false

    init(
        directoryURL: URL = VMResourceSampler.machineDirectory(named: SmolVMSetup.machineName, dataURL: SmolVMPaths.dataURL),
        log: @escaping @Sendable (String, String) -> Void = { ExternalState.shared.appendLog($0, $1) }
    ) {
        self.directoryURL = directoryURL
        self.log = log
    }

    func beginAttempt() {
        // Finish the previous stream before SmolVM truncates it for the next boot.
        collect(flushPartial: true)
        lastFailure = nil
        isStarting = true
    }

    func failureDetail() -> String? { lastFailure }

    func collect(flushPartial: Bool = false) {
        for name in ["agent-console.log", "agent-startup-error.log"] {
            let fileURL = directoryURL.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
            let modifiedAt = attributes[.modificationDate] as? Date
            var cursor = cursors[name] ?? Cursor(inode: inode, offset: isStarting ? 0 : size)
            if cursor.inode != inode || size < cursor.offset { cursor = Cursor(inode: inode) }
            guard cursors[name] == nil || size > cursor.offset || modifiedAt != cursor.modifiedAt,
                  let file = try? FileHandle(forReadingFrom: fileURL) else { continue }
            defer { try? file.close() }
            do {
                if cursor.offset > 0 {
                    let tailSize = min(cursor.offset, 64)
                    try file.seek(toOffset: cursor.offset - tailSize)
                    let tail = try file.read(upToCount: Int(tailSize)) ?? Data()
                    // Copy-truncate can refill past the old offset between polls.
                    if !cursor.tail.isEmpty && cursor.tail != tail { cursor = Cursor(inode: inode) }
                    else { cursor.tail = tail }
                }
                try file.seek(toOffset: cursor.offset)
                let data = try file.read(upToCount: 128 * 1024) ?? Data()
                cursor.offset += UInt64(data.count)
                cursor.tail.append(data)
                cursor.tail = Data(cursor.tail.suffix(64))
                cursor.modifiedAt = modifiedAt
                cursor.partial.append(data)
                while let newline = cursor.partial.firstIndex(of: 0x0a) {
                    record(String(decoding: cursor.partial[..<newline], as: UTF8.self))
                    cursor.partial.removeSubrange(...newline)
                }
                if cursor.partial.count > 32_768 {
                    record(String(decoding: cursor.partial.prefix(32_768), as: UTF8.self) + "… [truncated]")
                    cursor.partial.removeAll()
                }
                cursors[name] = cursor
            } catch { continue }
        }
        if flushPartial {
            for name in Array(cursors.keys) {
                guard let partial = cursors[name]?.partial, !partial.isEmpty else { continue }
                record(String(decoding: partial, as: UTF8.self))
                cursors[name]?.partial.removeAll()
            }
        }
    }

    private func record(_ line: String) {
        guard !line.isEmpty else { return }
        let docker = line.hasPrefix("time=") || line.hasPrefix("error initializing buildkit:") || line.hasPrefix("failed to start daemon") || line.hasPrefix("unable to configure the Docker daemon") || line.hasPrefix("panic:")
        log(docker ? "docker" : "smolvm", line)
        if docker && (line.contains("level=error") || !line.hasPrefix("time=")) {
            lastFailure = String(line.prefix(4_096))
        }
    }
}
