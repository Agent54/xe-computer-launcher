import Foundation

struct HostResourceReserveWarning: Codable, Equatable, Sendable {
    enum Resource: String, Codable, Sendable { case memory, disk }
    let resource: Resource
    let message: String
    let availableBytes: UInt64
    let minimumFreeBytes: UInt64
}

struct HostResourceReserveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HostResourcePolicy {
    static let gib: UInt64 = 1 << 30
    static let minimumFreeMemoryBytes = 4 * gib
    static let minimumFreeDiskBytes = 10 * gib

    static func nextMemoryMiB(after current: UInt32) -> UInt32? {
        let next = current < 8192 ? 8192 : UInt64(current) + 2048
        return next <= ContainerVMResources.maximumMemoryMiB ? UInt32(next) : nil
    }

    static func nextDiskGiB(after current: UInt64) -> UInt32? {
        guard current <= ContainerVMResources.maximumDiskGiB else { return nil }
        let next = current < 30 ? 30 : current + 10
        return next <= ContainerVMResources.maximumDiskGiB ? UInt32(next) : nil
    }

    static func warnings(for host: HostResourceSnapshot?) -> [HostResourceReserveWarning] {
        guard let host else { return [] }
        var warnings: [HostResourceReserveWarning] = []
        if let free = host.memoryAvailableBytes, free < minimumFreeMemoryBytes {
            warnings.append(.init(resource: .memory,
                message: "Host RAM is below its 4 GiB reserve: \(label(free)) available. Close other apps or reduce VM memory; do not increase the VM memory limit.",
                availableBytes: free, minimumFreeBytes: minimumFreeMemoryBytes))
        }
        if let free = host.diskAvailableBytes, free < minimumFreeDiskBytes {
            warnings.append(.init(resource: .disk,
                message: "Host disk space is below its 10 GiB reserve: \(label(free)) free on the VM storage volume. Free host disk space before increasing VM disk capacity.",
                availableBytes: free, minimumFreeBytes: minimumFreeDiskBytes))
        }
        return warnings
    }

    /// Credit only RAM already resident in this VM and storage blocks already
    /// allocated on the host. Fund the proposed limit, including sparse growth.
    static func validate(
        memoryMiB: UInt32? = nil, diskGiB: UInt64? = nil, host: HostResourceSnapshot,
        vmResidentBytes: UInt64 = 0, storageAllocatedBytes: UInt64 = 0
    ) throws {
        if let memoryMiB {
            guard let free = host.memoryAvailableBytes else {
                throw HostResourceReserveError(message: "Cannot verify the host's available RAM. The VM memory increase was blocked to preserve 4 GiB for the host.")
            }
            let credit = min(vmResidentBytes, host.memoryUsedBytes ?? 0)
            let available = free + credit // Bounded by the host's total RAM.
            let requested = UInt64(memoryMiB) * 1_048_576
            guard requested <= available, available - requested >= minimumFreeMemoryBytes else {
                let remaining = available > requested ? available - requested : 0
                throw HostResourceReserveError(message: "VM memory of \(label(requested)) would leave \(label(remaining)) available on the host. At least 4 GiB must remain available. Close other apps or choose a smaller VM memory limit.")
            }
        }
        if let diskGiB {
            guard let free = host.diskAvailableBytes, diskGiB <= ContainerVMResources.maximumDiskGiB else {
                throw HostResourceReserveError(message: "Cannot verify sufficient host disk space for this capacity. The disk increase was blocked to preserve 10 GiB for the host.")
            }
            let requested = diskGiB * gib
            let remainingGrowth = requested - min(requested, storageAllocatedBytes)
            guard remainingGrowth <= free, free - remainingGrowth >= minimumFreeDiskBytes else {
                let remaining = free > remainingGrowth ? free - remainingGrowth : 0
                throw HostResourceReserveError(message: "Allowing the VM disk to grow to \(diskGiB) GiB would leave \(label(remaining)) free on the host. At least 10 GiB must remain free. Free host disk space before increasing VM disk capacity.")
            }
        }
    }

    private static func label(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(gib))
    }
}
