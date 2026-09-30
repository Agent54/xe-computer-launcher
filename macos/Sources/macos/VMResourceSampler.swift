import CryptoKit
import Darwin
import Foundation

struct VMResourceSnapshot: Codable, Equatable, Sendable {
    let memoryResidentBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let balloonTargetBytes: UInt64?
    let balloonInflatedBytes: UInt64?
    let diskAllocatedBytes: UInt64?
    let diskLogicalBytes: UInt64?
}

enum VMResourceSampler {
    static func snapshot(machine: SmolVMMachine?, dataURL: URL = SmolVMPaths.dataURL) async -> VMResourceSnapshot {
        let directory = machineDirectory(named: SmolVMSetup.machineName, dataURL: dataURL)
        let running = machine?.isRunning == true
        let balloon = running
            ? await UnixSocketHTTP.balloonStatus(at: directory.appendingPathComponent("control.sock"))
                .flatMap(parseBalloonStatus)
            : nil
        let disk = diskUsage(in: directory)
        return VMResourceSnapshot(
            memoryResidentBytes: running ? machine?.pid.flatMap(residentMemoryBytes) : nil,
            memoryLimitBytes: machine?.memoryMiB.flatMap { bytes(fromMiB: $0) },
            balloonTargetBytes: balloon?.target,
            balloonInflatedBytes: balloon?.inflated,
            diskAllocatedBytes: disk?.allocated,
            diskLogicalBytes: disk?.logical
        )
    }

    // SmolVM stores named machines under the first eight bytes of SHA-256.
    static func machineDirectory(named name: String, dataURL: URL) -> URL {
        let hash = SHA256.hash(data: Data(name.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return dataURL.appendingPathComponent(hash, isDirectory: true)
    }

    static func residentMemoryBytes(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // RSS includes VMM overhead; compressed/swapped pages are not resident.
        return info.pti_resident_size
    }

    static func parseBalloonStatus(_ response: String) -> (target: UInt64, inflated: UInt64)? {
        let fields = response.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, fields[0] == "OK",
              fields[1].hasPrefix("target="), fields[2].hasPrefix("actual="),
              let targetMiB = UInt64(fields[1].dropFirst("target=".count)),
              let inflatedMiB = UInt64(fields[2].dropFirst("actual=".count)),
              let target = bytes(fromMiB: targetMiB),
              let inflated = bytes(fromMiB: inflatedMiB) else { return nil }
        return (target, inflated)
    }

    static func diskUsage(in directory: URL) -> (allocated: UInt64, logical: UInt64)? {
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        for name in ["storage", "overlay"] {
            let raw = directory.appendingPathComponent("\(name).raw")
            let qcow = directory.appendingPathComponent("\(name).qcow2")
            let path = FileManager.default.fileExists(atPath: qcow.path) ? qcow.path : raw.path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size >= 0, info.st_blocks >= 0 else { return nil }
            // st_blocks uses 512-byte units, including on APFS. This is the
            // file's allocated footprint; clone-shared blocks are not deduplicated.
            allocated += UInt64(info.st_blocks) * 512
            logical += UInt64(info.st_size)
        }
        return (allocated, logical)
    }

    private static func bytes(fromMiB value: UInt64) -> UInt64? {
        let (bytes, overflow) = value.multipliedReportingOverflow(by: 1024 * 1024)
        return overflow ? nil : bytes
    }
}
