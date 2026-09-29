import AppKit
import CoreFoundation
import Foundation

struct ContainerVMResources {
    static let memorySetting = "container_vm_memory_mib"
    static let cpuSetting = "container_vm_cpus"
    static let minimumMemoryMiB: UInt32 = 4096
    static let maximumMemoryMiB: UInt32 = 32768
    // Preserve the CPU allocation in the bundled Compose machine.
    static let defaultCPUs: UInt32 = 2

    let memoryMiB: UInt32
    let cpus: UInt32

    init(settings: [String: Any]?, hostCPUCount: Int = ProcessInfo.processInfo.processorCount) {
        let memory = Self.integer(settings?[Self.memorySetting]) ?? Int(Self.minimumMemoryMiB)
        memoryMiB = UInt32(clamping: min(Int(Self.maximumMemoryMiB), max(Int(Self.minimumMemoryMiB), memory)))
        let cpuCount = Self.integer(settings?[Self.cpuSetting]) ?? Int(Self.defaultCPUs)
        cpus = UInt32(clamping: min(max(1, hostCPUCount), max(1, cpuCount)))
    }

    var memoryGiBLabel: String { String(format: "%g", Double(memoryMiB) / 1024) }

    static func memoryMiB(fromGiB text: String) -> UInt32? {
        guard let gib = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), gib.isFinite,
              (Double(minimumMemoryMiB) / 1024...Double(maximumMemoryMiB) / 1024).contains(gib) else {
            return nil
        }
        return UInt32((gib * 1024).rounded())
    }

    static func cpuCount(from text: String, hostCPUCount: Int) -> UInt32? {
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...max(1, hostCPUCount)).contains(count) else { return nil }
        return UInt32(clamping: count)
    }

    private static func integer(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Int(exactly: number.doubleValue) ?? Int(number.stringValue)
        }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

@MainActor
enum ContainerVMSettings {
    enum Resource { case memory, cpus }

    static func change(_ resource: Resource) -> Bool {
        let state = ExternalState.shared
        let current = ContainerVMResources(settings: state.settings.rawData)
        let hostCPUs = ProcessInfo.processInfo.processorCount
        let hostMemoryGiB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let isMemory = resource == .memory
        let key = isMemory ? ContainerVMResources.memorySetting : ContainerVMResources.cpuSetting
        let oldValue = isMemory ? current.memoryMiB : current.cpus
        let input = NSTextField(string: isMemory ? current.memoryGiBLabel : String(current.cpus))
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        input.setAccessibilityLabel(isMemory ? "VM memory in GiB" : "VM CPU count")

        while true {
            let alert = NSAlert()
            alert.messageText = isMemory ? "Container VM Memory" : "Container VM CPUs"
            alert.informativeText = (isMemory
                ? "Enter a memory limit from 4 to 32 GiB. This Mac has \(String(format: "%g", hostMemoryGiB)) GiB. Memory is committed as needed."
                : "Enter a CPU limit from 1 to \(hostCPUs). This Mac has \(hostCPUs) logical CPUs.") +
                "\n\nShared by Docker builds and all containers. Changes apply when you quit and reopen Xe Launcher."
            alert.accessoryView = input
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = input
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            let value = isMemory
                ? ContainerVMResources.memoryMiB(fromGiB: input.stringValue)
                : ContainerVMResources.cpuCount(from: input.stringValue, hostCPUCount: hostCPUs)
            guard let value else {
                let warning = NSAlert()
                warning.alertStyle = .warning
                warning.messageText = isMemory ? "Invalid Memory Limit" : "Invalid CPU Limit"
                warning.informativeText = isMemory
                    ? "Enter a number from 4 to 32 GiB, such as 8 or 8.5."
                    : "Enter a whole number from 1 to \(hostCPUs)."
                warning.runModal()
                continue
            }
            guard value != oldValue else { return false }
            state.setIntegerSetting(key, Int(value))
            return true
        }
    }
}
