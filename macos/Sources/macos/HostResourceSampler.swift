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

    func snapshot() async -> HostResourceSnapshot {
        // Status can be published frequently; keep host sampling demand-driven and infrequent.
        let now = ContinuousClock.now
        if let cachedSnapshot, let lastSampledAt,
           now - lastSampledAt < Self.refreshInterval {
            return cachedSnapshot
        }

        // CPU usage needs two readings. Take the initial pair now instead of
        // caching an unavailable CPU percentage for the full refresh interval.
        let baselineCPUTicks = previousCPUTicks ?? Self.cpuTicks()
        if previousCPUTicks == nil, baselineCPUTicks != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let currentCPUTicks = Self.cpuTicks()
        let cpuPercent: Double?
        if let previousCPUTicks = baselineCPUTicks, let currentCPUTicks {
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
        lastSampledAt = ContinuousClock.now
        return snapshot
    }

    private static func cpuTicks() -> CPUTicks? {
        // Per-processor counters stay current during the short startup sample;
        // host_statistics can return rate-limited, cached aggregate counters.
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count
        )
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            _ = vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        guard cpuCount > 0, Int(count) >= Int(cpuCount) * Int(CPU_STATE_MAX) else { return nil }

        var busy: UInt64 = 0
        var idle: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            for state in [CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_NICE] {
                busy += UInt64(UInt32(bitPattern: info[offset + Int(state)]))
            }
            idle += UInt64(UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]))
        }
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
