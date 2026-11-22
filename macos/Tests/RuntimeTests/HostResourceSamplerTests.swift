import Testing
@testable import macos

struct HostResourceSamplerTests {
    @Test func firstSnapshotIncludesLiveCPUUsage() async throws {
        let sampler = HostResourceSampler()
        let snapshot = await sampler.snapshot()
        let cpuPercent = try #require(snapshot.cpuPercent)
        #expect((0...100).contains(cpuPercent))
    }

    @Test func freshSnapshotKeepsTheMeasuredCPUUsage() async throws {
        let sampler = HostResourceSampler()
        let first = await sampler.snapshot()
        _ = try #require(first.cpuPercent)
        let second = await sampler.snapshot()
        #expect(second == first)
    }
}
