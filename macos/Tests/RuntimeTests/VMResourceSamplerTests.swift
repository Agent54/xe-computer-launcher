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

    @Test func balloonUsesReportedInflationAndPreservesZero() throws {
        let sample = try #require(VMResourceSampler.parseBalloonStatus("OK target=1024 actual=768\n"))
        #expect(sample.target == 1024 * 1024 * 1024)
        #expect(sample.inflated == 768 * 1024 * 1024)
        #expect(VMResourceSampler.parseBalloonStatus("OK target=0 actual=0")?.inflated == 0)
    }

    @Test(arguments: ["ERR ENODEV no balloon device", "OK target=1", "OK target=-1 actual=0", "OK target=18446744073709551615 actual=0"])
    func unavailableAndInvalidBalloonSamplesStayUnavailable(response: String) {
        #expect(VMResourceSampler.parseBalloonStatus(response) == nil)
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

    @Test func stoppedMachineDoesNotSampleLiveMemoryOrBalloon() async {
        let machine = SmolVMMachine(name: "xe-launcher", state: "stopped", labels: nil, memory: nil, workload: nil, pid: getpid(), memoryMiB: 8192)
        let sample = await VMResourceSampler.snapshot(machine: machine, dataURL: URL(fileURLWithPath: "/tmp/missing-smol-\(UUID().uuidString)"))
        #expect(sample.memoryResidentBytes == nil)
        #expect(sample.memoryLimitBytes == UInt64(8192) * 1024 * 1024)
        #expect(sample.balloonInflatedBytes == nil)
        #expect(sample.diskAllocatedBytes == nil)
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
