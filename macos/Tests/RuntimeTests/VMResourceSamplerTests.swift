import Darwin
import Foundation
import Synchronization
import Testing
@testable import macos

struct VMResourceSamplerTests {
    @Test func machineDirectoryMatchesSmolVM() {
        let root = URL(fileURLWithPath: "/tmp/smol")
        #expect(VMResourceSampler.machineDirectory(named: "xe-launcher", dataURL: root).lastPathComponent == "a45ecb7e9f9267f3")
    }

    @Test func sparseImagesUseAllocatedBlocksAndExcludeOtherFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/xe-vm-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["storage.raw", "overlay.raw"] {
            let path = root.appendingPathComponent(name).path
            let descriptor = open(path, O_CREAT | O_WRONLY, 0o600)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            try #require(ftruncate(descriptor, 1024 * 1024 * 1024) == 0)
            let bytes = [UInt8](repeating: 1, count: 4096)
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, bytes.count) }
            try #require(written == bytes.count)
            // Settle APFS's delayed allocation before comparing block counts.
            try #require(fsync(descriptor) == 0)
        }
        let before = try #require(VMResourceSampler.diskUsage(in: root))
        #expect(before.logical == 2 * 1024 * 1024 * 1024)
        #expect(before.allocated > 0)
        #expect(before.allocated < before.logical / 2)
        try Data(repeating: 1, count: 1024 * 1024).write(to: root.appendingPathComponent("agent-console.log"))
        #expect(VMResourceSampler.diskUsage(in: root)?.allocated == before.allocated)
        // Prefer the active CoW disk, without counting its inactive raw copy.
        try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("storage.qcow2"))
        #expect(VMResourceSampler.diskUsage(in: root)?.logical == 1024 * 1024 * 1024 + 4096)
    }

    @Test func missingOrSymlinkedDisksStayUnavailable() throws {
        let root = URL(fileURLWithPath: "/tmp/xe-vm-resources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VMResourceSampler.diskUsage(in: root) == nil)
        try Data().write(to: root.appendingPathComponent("overlay.raw"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("storage.raw"), withDestinationURL: root.appendingPathComponent("overlay.raw"))
        #expect(VMResourceSampler.diskUsage(in: root) == nil)
    }

    @Test func samplesResidentMemoryWithoutTreatingUnavailableAsZero() throws {
        #expect(try #require(VMResourceSampler.residentMemoryBytes(pid: getpid())) > 0)
        #expect(VMResourceSampler.residentMemoryBytes(pid: -1) == nil)
    }

    @Test func stoppedMachineDoesNotSampleLiveMemory() async {
        let machine = SmolVMMachine(name: "xe-launcher", state: "stopped", labels: nil, memory: nil, workload: nil, pid: getpid(), memoryMiB: 8192)
        let sample = await VMResourceSampler.snapshot(machine: machine, dataURL: URL(fileURLWithPath: "/tmp/missing-smol-\(UUID().uuidString)"))
        #expect(sample.memoryResidentBytes == nil)
        #expect(sample.memoryLimitBytes == UInt64(8192) * 1024 * 1024)
        #expect(sample.diskAllocatedBytes == nil)
        #expect(sample.diskAvailableBytes == nil)
        #expect(sample.diskFreeInodes == nil)
    }

    @Test func guestDiskCountersReportWritableSpaceAndInodes() throws {
        let disk = try #require(VMResourceSampler.parseGuestDiskStatus("4096 5155829 39913 1310720 631409\n"))
        #expect(disk.totalBytes == 21_118_275_584)
        #expect(disk.availableBytes == 163_483_648)
        #expect(disk.totalInodes == 1_310_720)
        #expect(disk.freeInodes == 631_409)
        let full = try #require(VMResourceSampler.parseGuestDiskStatus("4096 100 0 1000 0"))
        #expect(full.availableBytes == 0)
        #expect(full.freeInodes == 0)
        let noInodeCounters = try #require(VMResourceSampler.parseGuestDiskStatus("4096 100 10 0 0"))
        #expect(noInodeCounters.totalInodes == nil)
        #expect(noInodeCounters.freeInodes == nil)
    }

    @Test(arguments: [
        "", "stat: cannot read file system information", "4096 100 10 1000",
        "0 100 10 1000 100", "4096 0 0 1000 100", "4096 100 -1 1000 100",
        "4096 100 101 1000 100", "4096 100 10 1000 1001",
        "4096 18446744073709551615 10 1000 100"
    ])
    func invalidGuestDiskCountersStayUnavailable(response: String) {
        #expect(VMResourceSampler.parseGuestDiskStatus(response) == nil)
    }

    @Test func guestDiskIsCachedForOneMinuteAndRefreshedAfterRestart() async {
        let reads = Mutex(0)
        let sampler = VMGuestDiskSampler { _ in
            let count = reads.withLock { $0 += 1; return $0 }
            return VMGuestDiskSnapshot(totalBytes: 1000, availableBytes: UInt64(count), totalInodes: 100, freeInodes: 10)
        }
        var machine = SmolVMMachine(name: "xe-launcher", state: "running", labels: nil, memory: nil, workload: nil, pid: 1)
        let start = ContinuousClock.now
        #expect(await sampler.sample(machine: machine, at: start)?.availableBytes == 1)
        #expect(await sampler.sample(machine: machine, at: start + .seconds(59))?.availableBytes == 1)
        #expect(reads.withLock { $0 } == 1)
        #expect(await sampler.sample(machine: machine, at: start + .seconds(60))?.availableBytes == 2)
        machine.pid = 2
        #expect(await sampler.sample(machine: machine, at: start + .seconds(61))?.availableBytes == 3)
        #expect(reads.withLock { $0 } == 3)
    }

    @Test func guestDiskFailuresAreThrottledAndStoppedMachinesAreNotQueried() async {
        let reads = Mutex(0)
        let sampler = VMGuestDiskSampler { _ in
            reads.withLock { $0 += 1 }
            return nil
        }
        let running = SmolVMMachine(name: "xe-launcher", state: "running", labels: nil, memory: nil, workload: nil, pid: 1)
        let stopped = SmolVMMachine(name: "xe-launcher", state: "stopped", labels: nil, memory: nil, workload: nil, pid: 1)
        let start = ContinuousClock.now
        #expect(await sampler.sample(machine: nil, at: start) == nil)
        #expect(await sampler.sample(machine: stopped, at: start) == nil)
        #expect(reads.withLock { $0 } == 0)
        #expect(await sampler.sample(machine: running, at: start) == nil)
        #expect(await sampler.sample(machine: running, at: start + .seconds(59)) == nil)
        #expect(reads.withLock { $0 } == 1)
        #expect(await sampler.sample(machine: running, at: start + .seconds(60)) == nil)
        #expect(reads.withLock { $0 } == 2)
        #expect(await sampler.sample(machine: stopped, at: start + .seconds(61)) == nil)
        #expect(await sampler.sample(machine: running, at: start + .seconds(62)) == nil)
        #expect(reads.withLock { $0 } == 3)
    }

    @Test func concurrentGuestDiskRequestsShareTheSameSamplingInterval() async {
        let reads = Mutex(0)
        let sampler = VMGuestDiskSampler { _ in
            reads.withLock { $0 += 1 }
            await Task.yield()
            return VMGuestDiskSnapshot(totalBytes: 1000, availableBytes: 10, totalInodes: nil, freeInodes: nil)
        }
        let machine = SmolVMMachine(name: "xe-launcher", state: "running", labels: nil, memory: nil, workload: nil, pid: 1)
        let start = ContinuousClock.now
        async let first = sampler.sample(machine: machine, at: start)
        async let second = sampler.sample(machine: machine, at: start)
        let results = await [first, second]
        #expect(results.contains { $0?.availableBytes == 10 })
        #expect(reads.withLock { $0 } == 1)
        #expect(await sampler.sample(machine: machine, at: start + .seconds(1))?.availableBytes == 10)
    }

    @Test func diskAllocationIsSampledAtMostOncePerMinute() async {
        let reads = Mutex(0)
        let sampler = VMImageDiskSampler { _ in
            reads.withLock {
                $0 += 1
                return (UInt64($0), 1024)
            }
        }
        let root = URL(fileURLWithPath: "/unused-vm-images")
        let start = ContinuousClock.now
        #expect(await sampler.sample(in: root, at: start)?.allocated == 1)
        #expect(await sampler.sample(in: root, at: start + .seconds(59))?.allocated == 1)
        #expect(await sampler.sample(in: root, at: start + .seconds(60))?.allocated == 2)
        #expect(reads.withLock { $0 } == 2)
    }

    @Test func unavailableDiskAllocationDoesNotCauseRepeatedRequests() async {
        let reads = Mutex(0)
        let sampler = VMImageDiskSampler { _ in
            reads.withLock { $0 += 1 }
            return nil
        }
        let root = URL(fileURLWithPath: "/unused-vm-images")
        let start = ContinuousClock.now
        #expect(await sampler.sample(in: root, at: start) == nil)
        #expect(await sampler.sample(in: root, at: start + .seconds(59)) == nil)
        #expect(reads.withLock { $0 } == 1)
        #expect(await sampler.sample(in: root, at: start + .seconds(60)) == nil)
        #expect(reads.withLock { $0 } == 2)
    }
}
