import Foundation

enum DockerDaemonConfiguration {
    static let guestDirectory = "/etc/docker"

    /// Prepare the host-owned configuration before boot and return its read-only mount.
    static func prepare(in directoryURL: URL, diskGiB: UInt64) throws -> String {
        let configurationURL = directoryURL.appendingPathComponent("daemon.json")
        let current: Data
        do {
            current = try Data(contentsOf: configurationURL)
        } catch CocoaError.fileReadNoSuchFile {
            current = Data("{}".utf8)
        }
        if let updated = try updatedConfiguration(current, diskGiB: diskGiB) {
            let fm = FileManager.default
            try fm.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try updated.write(to: configurationURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        }
        return "\(directoryURL.path):\(guestDirectory):ro"
    }

    static func updatedConfiguration(_ data: Data, diskGiB: UInt64) throws -> Data? {
        let (diskTotalBytes, overflow) = diskGiB.multipliedReportingOverflow(by: 1 << 30)
        guard diskGiB > 0, !overflow else { throw DockerDaemonConfigurationError.invalidCapacity }
        guard let current = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerDaemonConfigurationError.invalidConfiguration
        }
        var updated = current
        updated["log-driver"] = ContainerRuntimeMaintenance.loggingDriver
        // Options from another driver may not be supported by the local driver.
        updated["log-opts"] = ContainerRuntimeMaintenance.loggingOptions

        var builder = updated["builder"] as? [String: Any] ?? [:]
        var gc = builder["gc"] as? [String: Any] ?? [:]
        gc["enabled"] = true
        gc["defaultMaxUsedSpace"] = ContainerRuntimeMaintenance.buildCacheMaximum
        gc["defaultReservedSpace"] = ContainerRuntimeMaintenance.buildCacheReserve
        // Docker 28 validates percentages but its BuildKit startup parser only accepts byte sizes.
        gc["defaultMinFreeSpace"] = String(
            ContainerRuntimeMaintenance.buildCacheMinimumFreeBytes(diskTotalBytes: diskTotalBytes)
        )
        // Use Docker's standard GC policies with this budget. Custom policies
        // and the legacy reserve setting can override the configured maximum.
        gc.removeValue(forKey: "policy")
        gc.removeValue(forKey: "defaultKeepStorage")
        builder["gc"] = gc
        updated["builder"] = builder

        guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return nil }
        return try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
    }
}

enum DockerDaemonConfigurationError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidCapacity

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Docker daemon configuration must be a JSON object."
        case .invalidCapacity: "The Docker data disk capacity is invalid."
        }
    }
}
