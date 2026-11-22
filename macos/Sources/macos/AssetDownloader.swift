import Foundation
import AppKit
import CryptoKit
import Darwin
import ResumableDownloads
import Security

private let trustedXeComputerReleaseRoot = "https://github.com/Agent54/xe-darc/releases/download"
private let trustedHeliumReleaseRoot = "https://github.com/imputnet/helium-macos/releases/download"
private let trustedHeliumBundleIdentifier = "net.imput.helium"
private let trustedHeliumTeamIdentifier = "S4Q33XPHB4"

private enum SourceAssetFormat {
    case file
    case zip
    case darcBundle(version: String)
    case heliumDiskImage(version: String)
}

private struct SourceAsset {
    let url: URL
    let relativePath: String
    let format: SourceAssetFormat
    let expectedSHA256: String?
}

private func trustedSourceAsset(name: String, info: [String: Any]) -> SourceAsset? {
    if name == "darc" {
        guard let version = info["version"] as? [String: Any],
              let major = version["major"] as? Int,
              let minor = version["minor"] as? Int,
              let patch = version["patch"] as? Int,
              version.count == 3,
              let expectedSHA256 = info["sha256"] as? String, isValidSHA256(expectedSHA256),
              [major, minor, patch].allSatisfy({ (0...999_999_999).contains($0) }) else {
            return nil
        }

        let versionNumber = "\(major).\(minor).\(patch)"
        guard let url = URL(string: "\(trustedXeComputerReleaseRoot)/v\(versionNumber)/darc.swbn") else {
            return nil
        }
        // The upstream asset has a stable name, so make the local marker
        // version-specific. A newly pinned launcher version will then fetch and
        // install its required bundle even when an older bundle is cached.
        return SourceAsset(
            url: url,
            relativePath: "darc/\(versionNumber)/darc.swbn",
            format: .darcBundle(version: versionNumber),
            expectedSHA256: expectedSHA256.lowercased()
        )
    }

    if name == "helium" {
        guard let version = info["version"] as? String,
              isValidHeliumVersion(version),
              let expectedSHA256 = info["sha256"] as? String,
              isValidSHA256(expectedSHA256),
              let url = URL(
                string: "\(trustedHeliumReleaseRoot)/\(version)/helium_\(version)_arm64-macos.dmg"
              ) else {
            return nil
        }
        return SourceAsset(
            url: url,
            relativePath: url.lastPathComponent,
            format: .heliumDiskImage(version: version),
            expectedSHA256: expectedSHA256.lowercased()
        )
    }

    guard let urlString = info["url"] as? String, !urlString.isEmpty else {
        return nil
    }
    guard let url = URL(string: urlString) else { return nil }
    return SourceAsset(
        url: url,
        relativePath: url.lastPathComponent,
        format: (info["unzip"] as? Bool ?? true) ? .zip : .file,
        expectedSHA256: nil
    )
}

private func isValidHeliumVersion(_ version: String) -> Bool {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    return components.count == 4 && components.allSatisfy { component in
        !component.isEmpty
            && component.count <= 9
            && component.utf8.allSatisfy { (48...57).contains($0) }
    }
}

private func isValidSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
}

private func sourceConfigurations(in bundle: Bundle = .main) -> [String: [String: Any]]? {
    guard let sourcesURL = bundle.resourceURL?.appendingPathComponent("sources.json"),
          let sourcesData = try? Data(contentsOf: sourcesURL) else {
        return nil
    }
    return try? JSONSerialization.jsonObject(with: sourcesData) as? [String: [String: Any]]
}

func installedConfiguredDarcSourceURL(dataURL: URL, bundle: Bundle = .main) -> URL? {
    guard let info = sourceConfigurations(in: bundle)?["darc"],
          let asset = trustedSourceAsset(name: "darc", info: info),
          case .darcBundle = asset.format, let checksum = asset.expectedSHA256 else {
        return nil
    }
    return cachedDarcSource(at: dataURL.appendingPathComponent(asset.relativePath), expectedSHA256: checksum)
}

/// Derives the selected profile's active Darc version directly from the
/// configured versioned source asset and Chromium's profile bundle.
func activeConfiguredDarcBundleActivation(
    dataURL: URL,
    profileName: String,
    bundle: Bundle = .main
) -> DarcProfileBundleActivation? {
    guard let info = sourceConfigurations(in: bundle)?["darc"],
          let asset = trustedSourceAsset(name: "darc", info: info),
          case let .darcBundle(expectedVersion) = asset.format, let checksum = asset.expectedSHA256 else {
        return nil
    }
    return activeDarcBundleActivation(
        dataURL: dataURL,
        profileName: profileName,
        sourceURL: dataURL.appendingPathComponent(asset.relativePath),
        expectedVersion: expectedVersion, expectedSHA256: checksum
    )
}

/// Reconciles Chromium's profile-owned `main.swbn` with the configured,
/// versioned Darc asset. The caller must ensure the managed browser is stopped
/// so Chromium cannot retain an open reader for the old bundle.
@discardableResult
func activateConfiguredDarcBundle(
    dataURL: URL,
    profileNames: Set<String>? = nil,
    browserIsRunning: Bool,
    bundle: Bundle = .main,
    log: @escaping (String, String) -> Void
) -> DarcBundleActivationSummary? {
    guard !browserIsRunning else {
        log("launcher", "Deferred Xe Computer bundle activation because Chromium is still running")
        return nil
    }
    guard let info = sourceConfigurations(in: bundle)?["darc"],
          let asset = trustedSourceAsset(name: "darc", info: info),
          case let .darcBundle(expectedVersion) = asset.format, let checksum = asset.expectedSHA256 else {
        log("launcher", "Invalid Xe Computer source configuration; profile bundle was not changed")
        return nil
    }

    let sourceURL = dataURL.appendingPathComponent(asset.relativePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        return nil
    }

    do {
        return try activateDarcBundle(
            sourceURL: sourceURL,
            expectedVersion: expectedVersion,
            expectedSHA256: checksum,
            dataURL: dataURL,
            profileNames: profileNames,
            log: { message in log("launcher", message) }
        )
    } catch {
        log("launcher", "Xe Computer bundle activation failed: \(error.localizedDescription)")
        return nil
    }
}

func heliumVersionedAppURL(dataURL: URL, version: String) -> URL {
    dataURL
        .appendingPathComponent("helium", isDirectory: true)
        .appendingPathComponent(version, isDirectory: true)
        .appendingPathComponent("Helium.app", isDirectory: true)
}

private func configuredHeliumVersion(in bundle: Bundle = .main) -> String? {
    guard let info = sourceConfigurations(in: bundle)?["helium"],
          let asset = trustedSourceAsset(name: "helium", info: info),
          case let .heliumDiskImage(version) = asset.format else {
        return nil
    }
    return version
}

private struct InstalledHeliumCandidate {
    let appURL: URL
    let version: [Int]
}

func bestInstalledHeliumAppURL(
    dataURL: URL, requiredVersion: String?,
    verify: (URL) throws -> Void = verifyHeliumApplication
) -> URL? {
    let fm = FileManager.default
    let versionsRoot = dataURL.appendingPathComponent("helium", isDirectory: true)
    var candidates: [InstalledHeliumCandidate] = []

    if let versionDirectories = try? fm.contentsOfDirectory(
        at: versionsRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) {
        for versionDirectory in versionDirectories where isValidHeliumVersion(versionDirectory.lastPathComponent) {
            let appURL = versionDirectory.appendingPathComponent("Helium.app", isDirectory: true)
            let executable = appURL.appendingPathComponent("Contents/MacOS/Helium")
            guard fm.isExecutableFile(atPath: executable.path),
                  let installedVersion = heliumBundleVersion(at: appURL),
                  installedVersion == versionDirectory.lastPathComponent,
                  let components = numericVersionComponents(installedVersion),
                  (try? verify(appURL)) != nil else {
                continue
            }
            candidates.append(InstalledHeliumCandidate(appURL: appURL, version: components))
        }
    }

    // Releases before versioned engine directories used this location. Keep it
    // as a migration and rollback candidate until the user removes it.
    let legacyApp = dataURL.appendingPathComponent("Helium.app", isDirectory: true)
    let legacyExecutable = legacyApp.appendingPathComponent("Contents/MacOS/Helium")
    if fm.isExecutableFile(atPath: legacyExecutable.path),
       let installedVersion = heliumBundleVersion(at: legacyApp),
       let components = numericVersionComponents(installedVersion),
       (try? verify(legacyApp)) != nil {
        candidates.append(InstalledHeliumCandidate(appURL: legacyApp, version: components))
    }

    guard !candidates.isEmpty else { return nil }
    let requiredComponents = requiredVersion.flatMap(numericVersionComponents)
    let satisfyingCandidates = requiredComponents.map { required in
        candidates.filter { !$0.version.lexicographicallyPrecedes(required) }
    } ?? candidates
    return satisfyingCandidates.max {
        $0.version.lexicographicallyPrecedes($1.version)
    }?.appURL
}

func resolvedHeliumAppURL(dataURL: URL, bundle: Bundle = .main) -> URL? {
    guard let requiredVersion = configuredHeliumVersion(in: bundle) else { return nil }
    return bestInstalledHeliumAppURL(
        dataURL: dataURL,
        requiredVersion: requiredVersion
    )
}

func heliumBundleVersion(at appURL: URL) -> String? {
    let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let values = plist as? [String: Any] else {
        return nil
    }
    return values["CFBundleShortVersionString"] as? String
}

func heliumRequiresInstallation(
    at appURL: URL, requiredVersion: String,
    verify: (URL) throws -> Void = verifyHeliumApplication
) -> Bool {
    guard (try? verify(appURL)) != nil,
          let installedVersion = heliumBundleVersion(at: appURL),
          let installedComponents = numericVersionComponents(installedVersion),
          let requiredComponents = numericVersionComponents(requiredVersion) else {
        return true
    }
    return installedComponents.lexicographicallyPrecedes(requiredComponents)
}

func verifyHeliumApplication(at appURL: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/Helium").path) else {
        throw AssetInstallationError("Helium executable is missing")
    }
    try verifyApplicationSignature(at: appURL, requirement:
        "anchor apple generic and identifier \"\(trustedHeliumBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(trustedHeliumTeamIdentifier)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
}

func verifyApplicationSignature(at appURL: URL, requirement: String) throws {
    var code: SecStaticCode?
    var rule: SecRequirement?
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
    let creation = SecStaticCodeCreateWithPath(appURL as CFURL, [], &code)
    let parsing = SecRequirementCreateWithString(requirement as CFString, [], &rule)
    guard creation == errSecSuccess, parsing == errSecSuccess, let code, let rule else {
        throw AssetInstallationError("Could not read Helium code signature")
    }
    let status = SecStaticCodeCheckValidity(code, flags, rule)
    guard status == errSecSuccess else {
        throw AssetInstallationError("Helium integrity verification failed: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }
}

private func numericVersionComponents(_ version: String) -> [Int]? {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return nil }
    let values = components.compactMap { Int($0) }
    return values.count == components.count ? values : nil
}

func sha256Hex(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func verifySourceChecksum(at fileURL: URL, expectedSHA256: String) throws {
    let actual = try sha256Hex(of: fileURL)
    guard isValidSHA256(expectedSHA256), actual == expectedSHA256.lowercased() else {
        throw AssetInstallationError("SHA-256 mismatch (expected \(expectedSHA256), got \(actual))")
    }
}

// Hold a shared directory lock through installation. A new setup pass can
// remove abandoned staging files once all other installers have released it.
func lockSourceDownloadCache(_ directory: URL, operation: Int32) throws -> FileHandle {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let lease = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard flock(fd, operation) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return lease
}

func pruneSourceDownloadCache(_ directory: URL, retaining urls: [URL]) throws {
    let lease: FileHandle
    do {
        lease = try lockSourceDownloadCache(directory, operation: LOCK_EX | LOCK_NB)
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == EWOULDBLOCK {
        return
    }
    defer { try? lease.close() }
    let fm = FileManager.default
    let keep = Set(urls.map { XEArchiveTransfer.partialFilename(for: $0) })
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
        let name = file.lastPathComponent
        guard !keep.contains(name),
              isValidSHA256(name) || UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        try fm.removeItem(at: file)
    }
}

func downloadSourceAsset(
    from url: URL, directory: URL, cancellation: CancellationToken,
    progress: @escaping (Double) -> Void
) throws -> URL {
    let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    var retries = 0
    while true {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        nonisolated(unsafe) var response: URLResponse?
        let task = try XEArchiveTransfer.task(for: request, directory: directory.path, queue: nil) { received, total in
            if total > 0 { progress(Double(received) / Double(total)) }
        } completion: { file, receivedResponse, error in
            response = receivedResponse
            do {
                if let error { throw error }
                try FileManager.default.moveItem(at: file, to: destination)
            } catch { failure = error }
            done.signal()
        }
        cancellation.start(task)
        done.wait()
        cancellation.finish(task)
        guard let failure else { return destination }
        guard !cancellation.isCancelled, retries < 3,
              XEArchiveTransfer.shouldRetry(failure, response: response) else { throw failure }
        guard cancellation.waitBeforeRetry(seconds: 1 << retries) else { throw URLError(.cancelled) }
        retries += 1
    }
}

/// Download and install assets defined in sources.json when their pinned version is absent.
/// Helium is checksum- and signature-verified, then installed into a versioned directory.
func downloadSourceAssetsIfNeeded(dataURL: URL, log: @escaping (String, String) -> Void) {
    let fm = FileManager.default
    let installationLease: FileHandle
    do {
        installationLease = try lockSourceDownloadCache(dataURL, operation: LOCK_EX | LOCK_NB)
    } catch {
        log("launcher", "Could not prepare asset installation: \(error.localizedDescription)")
        return
    }
    defer { try? installationLease.close() }
    recoverHeliumInstallations(dataURL: dataURL, log: { log("launcher", $0) })
    let cancel = beginSetupAttempt()

    guard let sources = sourceConfigurations() else {
        log("launcher", "No sources.json found in bundle, skipping asset download")
        return
    }

    struct AssetInfo {
        let name: String
        let label: String
        let url: URL
        let destination: URL
        let format: SourceAssetFormat
        let expectedSHA256: String?
    }
    var pending: [AssetInfo] = []
    for (name, info) in sources {
        guard let sourceAsset = trustedSourceAsset(name: name, info: info) else {
            log("launcher", "Invalid source configuration for \(name), skipping asset download")
            continue
        }
        let label = info["label"] as? String ?? name
        let destination = dataURL.appendingPathComponent(sourceAsset.relativePath)
        switch sourceAsset.format {
        case let .heliumDiskImage(requiredVersion):
            if bestInstalledHeliumAppURL(
                dataURL: dataURL,
                requiredVersion: requiredVersion
            ) != nil {
                continue
            }
        case .darcBundle:
            guard let checksum = sourceAsset.expectedSHA256 else { continue }
            let cached = cachedDarcSource(at: destination, expectedSHA256: checksum) { error in
                log("launcher", "Downloading a replacement for \(destination.path): \(error.localizedDescription)")
            }
            if cached != nil { continue }
        case .file, .zip:
            if fm.fileExists(atPath: destination.path) { continue }
        }
        pending.append(AssetInfo(
            name: name,
            label: label,
            url: sourceAsset.url,
            destination: destination,
            format: sourceAsset.format,
            expectedSHA256: sourceAsset.expectedSHA256
        ))
    }

    let cache = dataURL.appendingPathComponent(".downloads", isDirectory: true)
    if fm.fileExists(atPath: cache.path) {
        do {
            try pruneSourceDownloadCache(cache, retaining: pending.map(\.url))
        } catch {
            log("launcher", "Could not prune the setup download cache: \(error.localizedDescription)")
        }
    }
    guard !pending.isEmpty else { return }

    // Show progress on main thread (synchronous to ensure it's visible before we start)
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        showSetupProgress(message: dataURL.path)
        sem.signal()
    }
    sem.wait()

    let totalAssets = Double(pending.count)
    for (index, asset) in pending.enumerated() {
        if cancel.isCancelled { break }

        retryLoop: while !cancel.isCancelled {
            if cancel.isCancelled { break }

            DispatchQueue.main.async {
                updateSetupProgress(status: "Downloading \(asset.label)...", progress: (Double(index) / totalAssets) * 100)
            }

            log("launcher", "Downloading \(asset.name) from \(asset.url.absoluteString)")

            do {
                let lease = try lockSourceDownloadCache(cache, operation: LOCK_SH)
                defer { try? lease.close() }
                let downloadedFile = try downloadSourceAsset(
                    from: asset.url, directory: cache, cancellation: cancel
                ) { fraction in
                    DispatchQueue.main.async {
                        updateSetupProgress(progress: (Double(index) + fraction) / totalAssets * 100)
                    }
                }
                defer { try? fm.removeItem(at: downloadedFile) }
                if cancel.isCancelled { break retryLoop }

                let fileSize = (try? fm.attributesOfItem(atPath: downloadedFile.path)[.size] as? Int) ?? 0
                guard fileSize >= 1000 else {
                    throw AssetInstallationError("Downloaded file is too small (\(fileSize) bytes)")
                }
                log("launcher", "Downloaded \(asset.name): \(fileSize) bytes")

                if let expectedSHA256 = asset.expectedSHA256 {
                    DispatchQueue.main.async {
                        updateSetupProgress(status: "Verifying \(asset.label)...")
                    }
                    try verifySourceChecksum(at: downloadedFile, expectedSHA256: expectedSHA256)
                }

                DispatchQueue.main.async {
                    updateSetupProgress(status: "Installing \(asset.label)...")
                }
                switch asset.format {
                case .darcBundle:
                    guard let checksum = asset.expectedSHA256 else { throw AssetInstallationError("Missing Darc checksum") }
                    try installDarcSource(from: downloadedFile, at: asset.destination, expectedSHA256: checksum)
                    log("launcher", "Saved \(asset.name) to \(asset.destination.path)")
                case let .heliumDiskImage(version):
                    try installHelium(
                        from: downloadedFile,
                        requiredVersion: version,
                        dataURL: dataURL,
                        log: log
                    )
                case .zip:
                    try runProcess(
                        executable: "/usr/bin/ditto",
                        arguments: ["-x", "-k", downloadedFile.path, dataURL.path]
                    )
                    log("launcher", "Extracted \(asset.name) to \(dataURL.path)")
                case .file:
                    let destination = asset.destination
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: downloadedFile, to: destination)
                    log("launcher", "Saved \(asset.name) to \(destination.path)")
                }
                break retryLoop
            } catch {
                if cancel.isCancelled { break retryLoop }
                let message = "Failed to install \(asset.label): \(error.localizedDescription)"
                log("launcher", message)
                switch showSetupError(message: message) {
                case .retry:
                    continue retryLoop
                case .cancel:
                    cancel.cancel()
                    break retryLoop
                }
            }
        }
    }

    DispatchQueue.main.async {
        closeSetupProgress()
    }
}

private struct AssetInstallationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@discardableResult
private func runProcess(executable: String, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        throw AssetInstallationError(
            "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status "
                + "\(process.terminationStatus)\(detail.isEmpty ? "" : ": \(detail)")"
        )
    }
    return text
}

func publishHeliumDirectory(from staged: URL, to installed: URL) throws {
    let result = FileManager.default.fileExists(atPath: installed.path)
        ? renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP))
        : rename(staged.path, installed.path)
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Delete abandoned and invalid managed artifacts before the normal installer runs.
func recoverHeliumInstallations(
    dataURL: URL, verify: (URL) throws -> Void = verifyHeliumApplication,
    run: (String, [String]) throws -> String = { try runProcess(executable: $0, arguments: $1) },
    remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
    log: (String) -> Void = { _ in }
) {
    let fm = FileManager.default
    func entries(_ root: URL) -> [URL] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        do { return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch {
            log("Deferred Helium cleanup at \(root.path): \(error.localizedDescription)")
            return []
        }
    }
    let versions = dataURL.appendingPathComponent("helium")
    for directory in entries(versions) {
        let name = directory.lastPathComponent
        let parts = name.dropFirst().components(separatedBy: ".replaced-")
        let abandoned = name.hasPrefix(".") && parts.count == 2 &&
            isValidHeliumVersion(parts[0]) && UUID(uuidString: parts[1]) != nil
        let app = directory.appendingPathComponent("Helium.app")
        let invalid = isValidHeliumVersion(name) &&
            (heliumBundleVersion(at: app) != name || (try? verify(app)) == nil)
        guard abandoned || invalid else { continue }
        do {
            try remove(directory)
        } catch {
            log("Deferred Helium cleanup at \(directory.path): \(error.localizedDescription)")
        }
    }
    let staging = entries(dataURL).filter {
        $0.lastPathComponent.hasPrefix(".helium-update-") &&
            UUID(uuidString: String($0.lastPathComponent.dropFirst(".helium-update-".count))) != nil
    }
    guard !staging.isEmpty else { return }
    var mounts: [String] = []
    do {
        let info = try run("/usr/bin/hdiutil", ["info", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: Data(info.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            throw AssetInstallationError("Could not inspect disk image mounts before cleaning Helium staging")
        }
        for image in images {
            guard let entities = image["system-entities"] as? [[String: Any]] else {
                throw AssetInstallationError("Could not inspect disk image mount points")
            }
            mounts += entities.compactMap { $0["mount-point"] as? String }
        }
    } catch {
        log("Deferred Helium staging cleanup: \(error.localizedDescription)")
        return
    }
    for directory in staging {
        do {
            let mount = directory.appendingPathComponent("mount").resolvingSymlinksInPath().path
            if mounts.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == mount }) {
                _ = try run("/usr/bin/hdiutil", ["detach", mount])
            }
            try remove(directory)
        } catch {
            log("Deferred Helium cleanup at \(directory.path): \(error.localizedDescription)")
        }
    }
}

private func installHelium(
    from diskImage: URL,
    requiredVersion: String,
    dataURL: URL,
    log: @escaping (String, String) -> Void
) throws {
    let fm = FileManager.default
    let stagingRoot = dataURL.appendingPathComponent(".helium-update-\(UUID().uuidString)", isDirectory: true)
    let mountPoint = stagingRoot.appendingPathComponent("mount", isDirectory: true)
    let stagedVersion = stagingRoot.appendingPathComponent(requiredVersion, isDirectory: true)
    let stagedApp = stagedVersion.appendingPathComponent("Helium.app", isDirectory: true)
    let versionsRoot = dataURL.appendingPathComponent("helium", isDirectory: true)
    let installedVersion = versionsRoot.appendingPathComponent(requiredVersion, isDirectory: true)
    let installedApp = installedVersion.appendingPathComponent("Helium.app", isDirectory: true)

    try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    try fm.createDirectory(at: stagedVersion, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stagingRoot) }

    try runProcess(
        executable: "/usr/bin/hdiutil",
        arguments: [
            "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mountPoint.path, diskImage.path
        ]
    )
    var mounted = true
    defer {
        if mounted {
            _ = try? runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])
        }
    }

    let mountedApp = mountPoint.appendingPathComponent("Helium.app", isDirectory: true)
    guard fm.fileExists(atPath: mountedApp.path) else {
        throw AssetInstallationError("Helium.app is missing from the disk image")
    }
    try runProcess(
        executable: "/usr/bin/ditto",
        arguments: [mountedApp.path, stagedApp.path]
    )
    try runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])
    mounted = false

    guard heliumBundleVersion(at: stagedApp) == requiredVersion else {
        throw AssetInstallationError("Disk image does not contain Helium \(requiredVersion)")
    }
    guard Bundle(url: stagedApp)?.bundleIdentifier == trustedHeliumBundleIdentifier else {
        throw AssetInstallationError("Disk image contains an unexpected application identifier")
    }
    let executable = stagedApp.appendingPathComponent("Contents/MacOS/Helium")
    guard fm.isExecutableFile(atPath: executable.path) else {
        throw AssetInstallationError("Helium executable is missing")
    }
    // The upstream disk image currently contains Finder metadata on a nested
    // Sparkle executable. Those unsigned xattrs make strict verification fail,
    // even though removing them leaves all signed bytes unchanged.
    removeCodeSigningDetritusRecursively(at: stagedApp)
    try verifyHeliumApplication(at: stagedApp)

    try fm.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
    // A single rename/swap publishes the verified directory. A crash cannot
    // leave the installed version hidden under a replacement filename.
    try publishHeliumDirectory(from: stagedVersion, to: installedVersion)

    removeQuarantineRecursively(at: installedApp)
    log("launcher", "Installed Helium \(requiredVersion) at \(installedApp.path)")
}

/// Remove com.apple.quarantine xattr recursively using the C removexattr API.
private func removeQuarantineRecursively(at url: URL) {
    let fm = FileManager.default
    let quarantine = "com.apple.quarantine"

    func strip(_ path: String) {
        removexattr(path, quarantine, XATTR_NOFOLLOW)
    }

    strip(url.path)
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
    for case let fileURL as URL in enumerator {
        strip(fileURL.path)
    }
}

private func removeCodeSigningDetritusRecursively(at url: URL) {
    let fm = FileManager.default
    let attributes = ["com.apple.FinderInfo", "com.apple.ResourceFork"]

    func strip(_ path: String) {
        for attribute in attributes {
            removexattr(path, attribute, XATTR_NOFOLLOW)
        }
    }

    strip(url.path)
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
    for case let fileURL as URL in enumerator {
        strip(fileURL.path)
    }
}
