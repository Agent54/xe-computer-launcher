import Foundation
import Testing
@testable import macos

struct ContainerVMSettingsTests {
    @Test func existingMemorySettingAndPackCPUDefaultArePreserved() {
        let defaults = ContainerVMResources(settings: nil, hostCPUCount: 12)
        #expect(defaults.memoryMiB == 4096)
        #expect(defaults.cpus == 2)
        #expect(defaults.diskGiB == 20)
        let configured = ContainerVMResources(settings: [
            "container_vm_memory_mib": "8192", "container_vm_cpus": 6
        ], hostCPUCount: 12)
        #expect(configured.memoryMiB == 8192)
        #expect(configured.memoryGiBLabel == "8")
        #expect(configured.cpus == 6)
    }

    @Test func diskCapacityGrowsWithoutShrinkingExistingMachines() throws {
        let resources = ContainerVMResources(settings: ["container_vm_disk_gib": 64])
        #expect(resources.diskGiB == 64)
        #expect(resources.diskGiB(preserving: nil) == 64)
        #expect(resources.diskGiB(preserving: 128) == 128)
        #expect(resources.diskGiB(preserving: 20) == 64)
        #expect(ContainerVMResources.diskGiB(from: " 64 ", minimum: 32) == 64)
        for invalid in ["19", "31", "4097", "32.5", "-1", "nan", ""] {
            #expect(ContainerVMResources.diskGiB(from: invalid, minimum: 32) == nil)
        }
        #expect(ContainerVMResources.diskGiB(from: "4096") == 4096)
        #expect(ContainerVMResources(settings: ["container_vm_disk_gib": true]).diskGiB == 20)
        #expect(ContainerVMResources(settings: ["container_vm_disk_gib": Int.max]).diskGiB == 4096)
        let machine = try JSONDecoder().decode(SmolVMMachine.self, from: Data(
            #"{"name":"xe-launcher","state":"stopped","storage_gb":128}"#.utf8
        ))
        #expect(machine.storageGiB == 128)
        let legacy = try JSONDecoder().decode(SmolVMMachine.self, from: Data(
            #"{"name":"xe-launcher","state":"stopped"}"#.utf8
        ))
        #expect(legacy.storageGiB == nil)
    }

    @Test func persistedLimitsAreBoundedAndMalformedValuesUseDefaults() {
        let bounded = ContainerVMResources(settings: [
            "container_vm_memory_mib": Int.max, "container_vm_cpus": 99
        ], hostCPUCount: 12)
        #expect(bounded.memoryMiB == 32768)
        #expect(bounded.cpus == 12)
        let low = ContainerVMResources(settings: [
            "container_vm_memory_mib": -1, "container_vm_cpus": 0
        ], hostCPUCount: 12)
        #expect(low.memoryMiB == 4096)
        #expect(low.cpus == 1)
        let invalidSettings: [Any] = [true, 8.5, "bad", NSNumber(value: Double.infinity)]
        for invalid in invalidSettings {
            let fallback = ContainerVMResources(settings: [
                "container_vm_memory_mib": invalid, "container_vm_cpus": invalid
            ], hostCPUCount: 12)
            #expect(fallback.memoryMiB == 4096)
            #expect(fallback.cpus == 2)
        }
    }

    @Test func dialogsValidateUnitsAndRejectInvalidResourceLimits() {
        #expect(ContainerVMResources.memoryMiB(fromGiB: " 8.5 ") == 8704)
        #expect(ContainerVMResources.memoryMiB(fromGiB: "4") == 4096)
        #expect(ContainerVMResources.memoryMiB(fromGiB: "32") == 32768)
        for invalid in ["", "nan", "inf", "-8", "3", "33"] {
            #expect(ContainerVMResources.memoryMiB(fromGiB: invalid) == nil)
        }
        #expect(ContainerVMResources.cpuCount(from: " 6 ", hostCPUCount: 12) == 6)
        for invalid in ["", "0", "-1", "1.5", "13"] {
            #expect(ContainerVMResources.cpuCount(from: invalid, hostCPUCount: 12) == nil)
        }
    }
}
