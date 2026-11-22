import Foundation
import Testing
@testable import macos

struct HostResourcePolicyTests {
    private let gib: UInt64 = 1 << 30

    private func host(memoryFree: UInt64, diskFree: UInt64) -> HostResourceSnapshot {
        HostResourceSnapshot(cpuPercent: nil, cpuCount: 8,
            memoryUsedBytes: 32 * gib - memoryFree, memoryTotalBytes: 32 * gib,
            diskUsedBytes: 500 * gib - diskFree, diskTotalBytes: 500 * gib)
    }

    @Test func warningIncreasesFollowTheRequestedSequence() {
        for (current, next) in [(4096, 8192), (8192, 10240), (10240, 12288), (30720, 32768)] {
            #expect(HostResourcePolicy.nextMemoryMiB(after: UInt32(current)) == UInt32(next))
        }
        #expect(HostResourcePolicy.nextMemoryMiB(after: 32768) == nil)
        for (current, next) in [(20, 30), (30, 40), (40, 50), (64, 74)] {
            #expect(HostResourcePolicy.nextDiskGiB(after: UInt64(current)) == UInt32(next))
        }
        #expect(HostResourcePolicy.nextDiskGiB(after: 4090) == nil)
        #expect(HostResourcePolicy.nextDiskGiB(after: UInt64.max) == nil)
    }

    @Test func memoryLimitMustLeaveFourGiBAndCreditsOnlyResidentVMMemory() throws {
        try HostResourcePolicy.validate(memoryMiB: 8192, host: host(memoryFree: 12 * gib, diskFree: 100 * gib))
        #expect(throws: HostResourceReserveError.self) {
            try HostResourcePolicy.validate(memoryMiB: 8192, host: host(memoryFree: 12 * gib - 1, diskFree: 100 * gib))
        }
        try HostResourcePolicy.validate(memoryMiB: 8192, host: host(memoryFree: 8 * gib, diskFree: 100 * gib),
            vmResidentBytes: 4 * gib)
        #expect(throws: HostResourceReserveError.self) {
            try HostResourcePolicy.validate(memoryMiB: 8192, host: host(memoryFree: 8 * gib, diskFree: 100 * gib),
                vmResidentBytes: gib)
        }
    }

    @Test func sparseDiskGrowthMustLeaveTenGiBAndCreditsAllocatedStorageOnce() throws {
        try HostResourcePolicy.validate(diskGiB: 30, host: host(memoryFree: 16 * gib, diskFree: 40 * gib))
        #expect(throws: HostResourceReserveError.self) {
            try HostResourcePolicy.validate(diskGiB: 30, host: host(memoryFree: 16 * gib, diskFree: 40 * gib - 1))
        }
        // A 30 GiB disk with 20 GiB allocated can still consume another 10 GiB.
        try HostResourcePolicy.validate(diskGiB: 30, host: host(memoryFree: 16 * gib, diskFree: 20 * gib),
            storageAllocatedBytes: 20 * gib)
        #expect(throws: HostResourceReserveError.self) {
            try HostResourcePolicy.validate(diskGiB: 40, host: host(memoryFree: 16 * gib, diskFree: 20 * gib),
                storageAllocatedBytes: 20 * gib)
        }
    }

    @Test func liveWarningsUseAbsoluteReservesAndDoNotInventMissingCounters() throws {
        #expect(HostResourcePolicy.warnings(for: host(memoryFree: 4 * gib, diskFree: 10 * gib)).isEmpty)
        let warnings = HostResourcePolicy.warnings(for: host(memoryFree: 4 * gib - 1, diskFree: 10 * gib - 1))
        #expect(warnings.map(\.resource) == [.memory, .disk])
        #expect(warnings.map(\.minimumFreeBytes) == [4 * gib, 10 * gib])
        let missing = HostResourceSnapshot(cpuPercent: nil, cpuCount: 8, memoryUsedBytes: nil,
            memoryTotalBytes: 32 * gib, diskUsedBytes: nil, diskTotalBytes: nil)
        #expect(HostResourcePolicy.warnings(for: missing).isEmpty)
        #expect(throws: HostResourceReserveError.self) { try HostResourcePolicy.validate(memoryMiB: 8192, host: missing) }
        #expect(throws: HostResourceReserveError.self) { try HostResourcePolicy.validate(diskGiB: 30, host: missing) }
    }
}
