import Foundation

struct FileHandleUsage: Codable, Equatable, Sendable {
    let used: UInt64
    let limit: UInt64
    var available: UInt64 { limit - min(used, limit) }
}

struct ProcessFileDescriptors: Codable, Equatable, Sendable {
    let pid: UInt64
    let name: String
    let used: UInt64
    let softLimit: UInt64?
    let hardLimit: UInt64?
    let available: UInt64?
    let truncated: Bool
}

struct FileDescriptorSnapshot: Codable, Equatable, Sendable {
    let sampledAt: Date
    let bootId: String
    let containerId: String?
    let vm: FileHandleUsage?
    let processes: [ProcessFileDescriptors]
    let partial: Bool
    let processError: String?
}

/// Read kernel counters and only the selected container's process descriptors.
/// Cache both failures and in-flight reads so multiple UI requests cannot overlap.
actor VMFileDescriptorSampler {
    typealias Execute = @Sendable ([String]) async throws -> SmolVMCommandResult
    private struct Entry {
        let at: Date
        let task: Task<FileDescriptorSnapshot?, Never>
    }

    static let interval: TimeInterval = 10
    static let maximumProcesses = 256
    static let maximumDescriptorsPerProcess = 131_072
    private let execute: Execute
    private let now: @Sendable () -> Date
    private var bootId: String?
    private var entries: [String: Entry] = [:]

    init(execute: Execute? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        // Telemetry must not occupy the VM lifecycle command queue.
        let client = SmolVMClient()
        self.execute = execute ?? { command in
            try await client.execute(in: SmolVMSetup.machineName, command: command, timeout: "3s")
        }
        self.now = now
    }

    static func validContainerID(_ value: String) -> Bool {
        (12...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    func sample(containerID: String?, bootID: String) async -> FileDescriptorSnapshot? {
        guard containerID.map(Self.validContainerID) ?? true else { return nil }
        if bootId != bootID {
            for entry in entries.values { entry.task.cancel() }
            entries.removeAll()
            bootId = bootID
        }
        let at = now()
        let key = containerID ?? ""
        if let cached = entries[key], (0..<Self.interval).contains(at.timeIntervalSince(cached.at)) {
            let result = await cached.task.value
            return bootId == bootID ? result : nil
        }
        // Keep at most eight recent selections; idle containers are never polled.
        for (key, entry) in entries where !(0..<Self.interval).contains(at.timeIntervalSince(entry.at)) {
            entry.task.cancel()
            entries.removeValue(forKey: key)
        }
        if entries.count >= 8, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key {
            entries.removeValue(forKey: oldest)?.task.cancel()
        }
        let execute = self.execute
        let task = Task {
            guard let result = try? await execute(Self.command(containerID: containerID)), result.exitCode == 0,
                  !Task.isCancelled else { return nil as FileDescriptorSnapshot? }
            return Self.parse(result.standardOutput, containerID: containerID, bootID: bootID, at: at)
        }
        entries[key] = Entry(at: at, task: task)
        let result = await task.value
        return bootId == bootID ? result : nil
    }

    static func command(containerID: String?, procRoot: String = "/proc") -> [String] {
        ["/bin/sh", "-c", script, "fd-monitor", containerID ?? "",
         String(maximumProcesses), String(maximumDescriptorsPerProcess), procRoot]
    }

    static func parse(_ output: String, containerID: String?, bootID: String, at: Date) -> FileDescriptorSnapshot {
        var vm: FileHandleUsage?
        var processes: [ProcessFileDescriptors] = []
        var partial = false
        var error: String?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "VM", fields.count == 4, let allocated = UInt64(fields[1]),
               let unused = UInt64(fields[2]), unused <= allocated, let limit = UInt64(fields[3]), limit > 0 {
                vm = FileHandleUsage(used: allocated - unused, limit: limit)
            } else if fields.first == "PROCESS", fields.count == 8, let pid = UInt64(fields[1]), pid > 0,
                      let used = UInt64(fields[3]) {
                let truncated = fields[7] == "1"
                processes.append(ProcessFileDescriptors(pid: pid, name: String(fields[2]), used: used,
                    softLimit: UInt64(fields[4]), hardLimit: UInt64(fields[5]),
                    available: truncated ? nil : UInt64(fields[6]), truncated: truncated))
                partial = partial || truncated
            } else if fields.first == "PARTIAL" {
                partial = true
            } else if fields.first == "ERROR" {
                error = "Selected container process list is unavailable."
            }
        }
        return FileDescriptorSnapshot(sampledAt: at, bootId: bootID, containerId: containerID,
            vm: vm, processes: processes, partial: partial, processError: error)
    }

    // find reads only the numeric /proc FD entries, without following symlinks
    // or sorting/materializing a directory. awk stops the stream at a fixed cap.
    // Count available descriptor slots below the soft limit, even if a process
    // lowered its limit while retaining higher-numbered open descriptors.
    static let script = #"""
    proc_root="$4"
    if read -r allocated unused maximum < "$proc_root/sys/fs/file-nr"; then
      printf 'VM\t%s\t%s\t%s\n' "$allocated" "$unused" "$maximum"
    fi
    container="$1"; process_cap="$2"; descriptor_cap="$3"
    [ -n "$container" ] || exit 0
    if ! pids=$(docker top "$container" -eo pid 2>/dev/null); then
      printf 'ERROR\n'; exit 0
    fi
    seen=0
    printf '%s\n' "$pids" | while read -r pid rest; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      seen=$((seen + 1))
      if [ "$seen" -gt "$process_cap" ]; then printf 'PARTIAL\n'; break; fi
      base="$proc_root/$pid"
      before=$(awk '{ sub(/^.*\) /, ""); print $20 }' "$base/stat" 2>/dev/null)
      limits=$(awk '$1 == "Max" && $2 == "open" && $3 == "files" { print $4, $5 }' "$base/limits" 2>/dev/null)
      if [ -z "$before" ] || [ -z "$limits" ]; then printf 'PARTIAL\n'; continue; fi
      set -- $limits; soft="$1"; hard="$2"
      name=$(tr '\011\012\015' '   ' < "$base/comm" 2>/dev/null)
      counts=$(
        { find "$base/fd" -mindepth 1 -maxdepth 1 -print 2>/dev/null || printf 'READ_ERROR\n'; } |
        awk -F/ -v soft="$soft" -v cap="$descriptor_cap" '
          $0 == "READ_ERROR" { bad=1; next }
          $NF ~ /^[0-9]+$/ {
            used++; if (soft ~ /^[0-9]+$/ && $NF + 0 < soft + 0) occupied++;
            if (used >= cap) { truncated=1; exit }
          }
          END {
            if (bad) { print "unavailable"; exit }
            available = soft ~ /^[0-9]+$/ ? soft - occupied : "unlimited";
            printf "%d %s %d", used, available, truncated;
          }'
      )
      after=$(awk '{ sub(/^.*\) /, ""); print $20 }' "$base/stat" 2>/dev/null)
      if [ "$before" != "$after" ] || [ "$counts" = unavailable ]; then printf 'PARTIAL\n'; continue; fi
      set -- $counts
      printf 'PROCESS\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$name" "$1" "$soft" "$hard" "$2" "$3"
    done
    """#
}
