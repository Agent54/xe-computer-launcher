import Darwin
import Foundation

struct HostResourceSnapshot: Codable, Equatable, Sendable {
    let cpuPercent: Double?
    let cpuCount: Int
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64
    let diskUsedBytes: UInt64?
    let diskTotalBytes: UInt64?
}

actor HostResourceSampler {
    static let shared = HostResourceSampler()

    private static let refreshInterval: Duration = .seconds(60)

    private struct CPUTicks {
        let busy: UInt64
        let total: UInt64
    }

    private var previousCPUTicks: CPUTicks?
    private var cachedSnapshot: HostResourceSnapshot?
    private var lastSampledAt: ContinuousClock.Instant?

    func snapshot() -> HostResourceSnapshot {
        // Status can be published frequently; keep host sampling demand-driven and infrequent.
        let now = ContinuousClock.now
        if let cachedSnapshot, let lastSampledAt,
           now - lastSampledAt < Self.refreshInterval {
            return cachedSnapshot
        }

        let currentCPUTicks = Self.cpuTicks()
        let cpuPercent: Double?
        if let previousCPUTicks, let currentCPUTicks {
            let busy = currentCPUTicks.busy >= previousCPUTicks.busy
                ? currentCPUTicks.busy - previousCPUTicks.busy
                : 0
            let total = currentCPUTicks.total >= previousCPUTicks.total
                ? currentCPUTicks.total - previousCPUTicks.total
                : 0
            cpuPercent = total > 0 ? Double(busy) / Double(total) * 100 : nil
        } else {
            cpuPercent = nil
        }
        previousCPUTicks = currentCPUTicks

        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let disk = Self.diskUsage()
        let snapshot = HostResourceSnapshot(
            cpuPercent: cpuPercent,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            memoryUsedBytes: Self.memoryUsedBytes(totalBytes: memoryTotal),
            memoryTotalBytes: memoryTotal,
            diskUsedBytes: disk?.used,
            diskTotalBytes: disk?.total
        )
        cachedSnapshot = snapshot
        lastSampledAt = now
        return snapshot
    }

    private static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        return CPUTicks(busy: busy, total: busy + idle)
    }

    private static func memoryUsedBytes(totalBytes: UInt64) -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        let availablePages = UInt64(info.free_count) + UInt64(info.inactive_count)
        let availableBytes = min(totalBytes, availablePages * pageSize)
        return totalBytes - availableBytes
    }

    private static func diskUsage() -> (used: UInt64, total: UInt64)? {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
        let totalValue = values.volumeTotalCapacity,
        totalValue > 0 else { return nil }

        let total = UInt64(totalValue)
        let available = UInt64(clamping: values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (total - min(total, available), total)
    }
}
