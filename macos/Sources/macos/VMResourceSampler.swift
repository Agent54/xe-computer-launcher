import CryptoKit
import Darwin
import Foundation

struct VMResourceSnapshot: Codable, Equatable, Sendable {
    let memoryResidentBytes: UInt64?
    let memoryLimitBytes: UInt64?
    let diskAllocatedBytes: UInt64?
    let diskLogicalBytes: UInt64?
    let diskTotalBytes: UInt64?
    let diskAvailableBytes: UInt64?
    let diskTotalInodes: UInt64?
    let diskFreeInodes: UInt64?
    var diskCapacityGiB: UInt64? = nil
}

struct VMGuestDiskSnapshot: Equatable, Sendable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let totalInodes: UInt64?
    let freeInodes: UInt64?
}

enum VMResourceSampler {
    private static let diskSampler = VMImageDiskSampler()
    private static let guestDiskSampler = VMGuestDiskSampler()

    static func invalidateDiskSamples() async {
        await diskSampler.invalidate()
        await guestDiskSampler.invalidate()
    }

    static func snapshot(machine: SmolVMMachine?, dataURL: URL = SmolVMPaths.dataURL) async -> VMResourceSnapshot {
        let directory = machineDirectory(named: SmolVMSetup.machineName, dataURL: dataURL)
        let running = machine?.isRunning == true
        let disk = await diskSampler.sample(in: directory)
        let guestDisk = await guestDiskSampler.sample(machine: machine)
        return VMResourceSnapshot(
            memoryResidentBytes: running ? machine?.pid.flatMap(residentMemoryBytes) : nil,
            memoryLimitBytes: machine?.memoryMiB.flatMap { bytes(fromMiB: $0) },
            diskAllocatedBytes: disk?.allocated,
            diskLogicalBytes: disk?.logical,
            diskTotalBytes: guestDisk?.totalBytes,
            diskAvailableBytes: guestDisk?.availableBytes,
            diskTotalInodes: guestDisk?.totalInodes,
            diskFreeInodes: guestDisk?.freeInodes,
            diskCapacityGiB: machine?.storageGiB
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

    static func parseGuestDiskStatus(_ response: String) -> VMGuestDiskSnapshot? {
        // stat -f returns filesystem counters; it never traverses Docker's files.
        let fields = response.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5,
              let blockSize = UInt64(fields[0]), blockSize > 0,
              let totalBlocks = UInt64(fields[1]), totalBlocks > 0,
              let availableBlocks = UInt64(fields[2]), availableBlocks <= totalBlocks,
              let totalInodes = UInt64(fields[3]),
              let freeInodes = UInt64(fields[4]), freeInodes <= totalInodes else { return nil }
        let (totalBytes, totalOverflow) = blockSize.multipliedReportingOverflow(by: totalBlocks)
        let (availableBytes, availableOverflow) = blockSize.multipliedReportingOverflow(by: availableBlocks)
        guard !totalOverflow, !availableOverflow else { return nil }
        return VMGuestDiskSnapshot(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            totalInodes: totalInodes > 0 ? totalInodes : nil,
            freeInodes: totalInodes > 0 ? freeInodes : nil
        )
    }

    private static func bytes(fromMiB value: UInt64) -> UInt64? {
        let (bytes, overflow) = value.multipliedReportingOverflow(by: 1024 * 1024)
        return overflow ? nil : bytes
    }
}

actor VMGuestDiskSampler {
    private let read: @Sendable (String) async -> VMGuestDiskSnapshot?
    private var sampledName: String?
    private var sampledPID: Int32?
    private var lastSampledAt: ContinuousClock.Instant?
    private var cachedDisk: VMGuestDiskSnapshot?

    func invalidate() { lastSampledAt = nil }

    init(read: @escaping @Sendable (String) async -> VMGuestDiskSnapshot? = { name in
        guard let result = try? await SmolVMClient.shared.execute(
            in: name,
            command: ["stat", "-f", "-c", "%S %b %a %c %d", "/storage/docker"],
            timeout: "2s"
        ) else { return nil }
        return VMResourceSampler.parseGuestDiskStatus(result.standardOutput)
    }) {
        self.read = read
    }

    func sample(machine: SmolVMMachine?, at now: ContinuousClock.Instant = .now) async -> VMGuestDiskSnapshot? {
        guard let machine, machine.isRunning else {
            sampledName = nil
            sampledPID = nil
            lastSampledAt = nil
            cachedDisk = nil
            return nil
        }
        if sampledName == machine.name, sampledPID == machine.pid, let lastSampledAt,
           now - lastSampledAt < .seconds(60) {
            return cachedDisk
        }
        if sampledName != machine.name || sampledPID != machine.pid {
            cachedDisk = nil
        }
        sampledName = machine.name
        sampledPID = machine.pid
        // Stamp before awaiting so concurrent callers cannot launch another read.
        // Failures are cached too; restarting the VM invalidates the old sample.
        lastSampledAt = now
        let disk = await read(machine.name)
        guard sampledName == machine.name, sampledPID == machine.pid,
              lastSampledAt == now else { return nil }
        cachedDisk = disk
        return disk
    }
}

actor VMImageDiskSampler {
    typealias Allocation = (allocated: UInt64, logical: UInt64)

    private let read: @Sendable (URL) -> Allocation?
    private var sampledDirectory: URL?
    private var lastSampledAt: ContinuousClock.Instant?
    private var cachedAllocation: Allocation?

    func invalidate() { lastSampledAt = nil }

    init(read: @escaping @Sendable (URL) -> Allocation? = VMResourceSampler.diskUsage(in:)) {
        self.read = read
    }

    func sample(in directory: URL, at now: ContinuousClock.Instant = .now) -> Allocation? {
        if sampledDirectory == directory, let lastSampledAt,
           now - lastSampledAt < .seconds(60) {
            return cachedAllocation
        }
        // Read only the two image files' allocation metadata, never their contents
        // or container filesystems. Cache unavailable readings for the same interval.
        cachedAllocation = read(directory)
        sampledDirectory = directory
        lastSampledAt = now
        return cachedAllocation
    }
}
