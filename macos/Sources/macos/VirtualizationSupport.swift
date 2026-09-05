import Darwin

enum VirtualizationSupport {
    static var isAvailable: Bool {
        var supported: Int32 = 0
        var size = MemoryLayout.size(ofValue: supported)
        return sysctlbyname("kern.hv_support", &supported, &size, nil, 0) == 0 && supported == 1
    }

    static let unavailableWarning = "Warning: sub-VM not available; SmolVM and Compose startup skipped. Xe Launcher will continue without container services."
}
