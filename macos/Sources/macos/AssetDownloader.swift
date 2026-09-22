import Foundation
import AppKit
import CryptoKit
import Darwin

private let trustedXeComputerReleaseRoot = "https://github.com/Agent54/xe-darc/releases/download"
private let trustedHeliumReleaseRoot = "https://github.com/imputnet/helium-macos/releases/download"
private let trustedHeliumBundleIdentifier = "net.imput.helium"
private let trustedHeliumTeamIdentifier = "S4Q33XPHB4"

private enum SourceAssetFormat {
    case file
    case zip
    case diskImage
}

private struct SourceAsset {
    let url: URL
    let filename: String
    let format: SourceAssetFormat
    let expectedVersion: String?
    let expectedSHA256: String?
}

private func trustedSourceAsset(name: String, info: [String: Any]) -> SourceAsset? {
    if name == "darc" {
        guard let version = info["version"] as? [String: Any],
              let major = version["major"] as? Int,
              let minor = version["minor"] as? Int,
              let patch = version["patch"] as? Int,
              version.count == 3,
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
            filename: "darc.\(versionNumber).swbn",
            format: .file,
            expectedVersion: versionNumber,
            expectedSHA256: nil
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
            filename: "helium_\(version)_arm64-macos.dmg",
            format: .diskImage,
            expectedVersion: version,
            expectedSHA256: expectedSHA256.lowercased()
        )
    }

    guard let urlString = info["url"] as? String, !urlString.isEmpty else {
        return nil
    }
    guard let url = URL(string: urlString) else { return nil }
    return SourceAsset(
        url: url,
        filename: url.lastPathComponent,
        format: (info["unzip"] as? Bool ?? true) ? .zip : .file,
        expectedVersion: nil,
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

/// Returns the version-specific local file expected for a configured source asset.
func configuredSourceAssetURL(name: String, dataURL: URL, bundle: Bundle = .main) -> URL? {
    guard let info = sourceConfigurations(in: bundle)?[name],
          let asset = trustedSourceAsset(name: name, info: info) else {
        return nil
    }
    return dataURL.appendingPathComponent(asset.filename)
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
          let expectedVersion = asset.expectedVersion else {
        return nil
    }
    return activeDarcBundleActivation(
        dataURL: dataURL,
        profileName: profileName,
        sourceURL: dataURL.appendingPathComponent(asset.filename),
        expectedVersion: expectedVersion
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
          let expectedVersion = asset.expectedVersion else {
        log("launcher", "Invalid Xe Computer source configuration; profile bundle was not changed")
        return nil
    }

    let sourceURL = dataURL.appendingPathComponent(asset.filename)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        return nil
    }

    do {
        return try activateDarcBundle(
            sourceURL: sourceURL,
            expectedVersion: expectedVersion,
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
          let asset = trustedSourceAsset(name: "helium", info: info) else {
        return nil
    }
    return asset.expectedVersion
}

private struct InstalledHeliumCandidate {
    let appURL: URL
    let version: [Int]
}

func bestInstalledHeliumAppURL(dataURL: URL, requiredVersion: String?) -> URL? {
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
                  let components = numericVersionComponents(installedVersion) else {
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
       let components = numericVersionComponents(installedVersion) {
        candidates.append(InstalledHeliumCandidate(appURL: legacyApp, version: components))
    }

    guard !candidates.isEmpty else { return nil }
    let requiredComponents = requiredVersion.flatMap(numericVersionComponents)
    let satisfyingCandidates = requiredComponents.map { required in
        candidates.filter { !$0.version.lexicographicallyPrecedes(required) }
    } ?? candidates
    let selectionPool = satisfyingCandidates.isEmpty ? candidates : satisfyingCandidates
    return selectionPool.max {
        $0.version.lexicographicallyPrecedes($1.version)
    }?.appURL
}

func resolvedHeliumAppURL(dataURL: URL, bundle: Bundle = .main) -> URL? {
    bestInstalledHeliumAppURL(
        dataURL: dataURL,
        requiredVersion: configuredHeliumVersion(in: bundle)
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

func heliumRequiresInstallation(at appURL: URL, requiredVersion: String) -> Bool {
    guard let installedVersion = heliumBundleVersion(at: appURL),
          let installedComponents = numericVersionComponents(installedVersion),
          let requiredComponents = numericVersionComponents(requiredVersion) else {
        return true
    }
    return installedComponents.lexicographicallyPrecedes(requiredComponents)
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

/// Download and install assets defined in sources.json when their pinned version is absent.
/// Helium is checksum- and signature-verified, then installed into a versioned directory.
func downloadSourceAssetsIfNeeded(dataURL: URL, log: @escaping (String, String) -> Void) {
    let fm = FileManager.default

    guard let sources = sourceConfigurations() else {
        log("launcher", "No sources.json found in bundle, skipping asset download")
        return
    }

    struct AssetInfo {
        let name: String
        let label: String
        let url: URL
        let filename: String
        let format: SourceAssetFormat
        let expectedVersion: String?
        let expectedSHA256: String?
    }
    var pending: [AssetInfo] = []
    for (name, info) in sources {
        guard let sourceAsset = trustedSourceAsset(name: name, info: info) else {
            log("launcher", "Invalid source configuration for \(name), skipping asset download")
            continue
        }
        let label = info["label"] as? String ?? name
        if name == "helium", let requiredVersion = sourceAsset.expectedVersion {
            if let heliumApp = bestInstalledHeliumAppURL(
                dataURL: dataURL,
                requiredVersion: requiredVersion
            ), !heliumRequiresInstallation(at: heliumApp, requiredVersion: requiredVersion) {
                continue
            }
        } else {
            let fileMarker = dataURL.appendingPathComponent(sourceAsset.filename)
            if fm.fileExists(atPath: fileMarker.path) { continue }
        }
        pending.append(AssetInfo(
            name: name,
            label: label,
            url: sourceAsset.url,
            filename: sourceAsset.filename,
            format: sourceAsset.format,
            expectedVersion: sourceAsset.expectedVersion,
            expectedSHA256: sourceAsset.expectedSHA256
        ))
    }

    guard !pending.isEmpty else { return }

    // Show progress on main thread (synchronous to ensure it's visible before we start)
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        showSetupProgress(message: dataURL.path)
        sem.signal()
    }
    sem.wait()

    let cancel = setupCancellation

    let totalAssets = Double(pending.count)
    for (index, asset) in pending.enumerated() {
        if cancel.isCancelled { break }

        retryLoop: while !cancel.isCancelled {
            if cancel.isCancelled { break }

            DispatchQueue.main.async {
                updateSetupProgress(status: "Downloading \(asset.label)...", progress: (Double(index) / totalAssets) * 100)
            }

            log("launcher", "Downloading \(asset.name) from \(asset.url.absoluteString)")

            let downloadSem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var downloadedFileURL: URL?
            nonisolated(unsafe) var downloadError: Error?

            let delegate = DownloadProgressDelegate(onProgress: { fraction in
                DispatchQueue.main.async {
                    let base = (Double(index) / totalAssets) * 100
                    let portion = (1.0 / totalAssets) * 100
                    updateSetupProgress(progress: base + fraction * portion)
                }
            }, completion: { fileURL, error in
                if let error {
                    downloadError = error
                } else if let fileURL {
                    downloadedFileURL = fileURL
                }
                downloadSem.signal()
            })
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            let task = session.downloadTask(with: asset.url)
            cancel.activeTask = task
            task.resume()
            downloadSem.wait()
            cancel.activeTask = nil

            if cancel.isCancelled {
                if let f = downloadedFileURL { try? fm.removeItem(at: f) }
                break
            }

            do {
                if let error = downloadError { throw error }
                guard let downloadedFile = downloadedFileURL else {
                    throw AssetInstallationError("Download produced no file")
                }
                defer { try? fm.removeItem(at: downloadedFile) }

                let fileSize = (try? fm.attributesOfItem(atPath: downloadedFile.path)[.size] as? Int) ?? 0
                guard fileSize >= 1000 else {
                    throw AssetInstallationError("Downloaded file is too small (\(fileSize) bytes)")
                }
                log("launcher", "Downloaded \(asset.name): \(fileSize) bytes")

                if let expectedSHA256 = asset.expectedSHA256 {
                    DispatchQueue.main.async {
                        updateSetupProgress(status: "Verifying \(asset.label)...")
                    }
                    let actualSHA256 = try sha256Hex(of: downloadedFile)
                    guard actualSHA256 == expectedSHA256 else {
                        throw AssetInstallationError(
                            "SHA-256 mismatch (expected \(expectedSHA256), got \(actualSHA256))"
                        )
                    }
                }

                DispatchQueue.main.async {
                    updateSetupProgress(status: "Installing \(asset.label)...")
                }
                switch asset.format {
                case .diskImage:
                    guard asset.name == "helium", let version = asset.expectedVersion else {
                        throw AssetInstallationError("Unsupported disk image asset")
                    }
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
                    let destination = dataURL.appendingPathComponent(asset.filename)
                    if fm.fileExists(atPath: destination.path) {
                        try fm.removeItem(at: destination)
                    }
                    try fm.moveItem(at: downloadedFile, to: destination)
                    log("launcher", "Saved \(asset.name) to \(destination.path)")
                }
                break retryLoop
            } catch {
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
    let replacedVersion = versionsRoot.appendingPathComponent(
        ".\(requiredVersion).replaced-\(UUID().uuidString)",
        isDirectory: true
    )

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
    try runProcess(
        executable: "/usr/bin/codesign",
        arguments: ["--verify", "--deep", "--strict", "--verbose=2", stagedApp.path]
    )
    let signatureDetails = try runProcess(
        executable: "/usr/bin/codesign",
        arguments: ["-d", "--verbose=4", stagedApp.path]
    )
    guard signatureDetails.contains("Identifier=\(trustedHeliumBundleIdentifier)"),
          signatureDetails.contains("TeamIdentifier=\(trustedHeliumTeamIdentifier)"),
          signatureDetails.contains("Authority=Developer ID Application:") else {
        throw AssetInstallationError("Helium is not signed by the expected Developer ID team")
    }

    try fm.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
    if fm.fileExists(atPath: installedVersion.path) {
        try fm.moveItem(at: installedVersion, to: replacedVersion)
    }
    do {
        // Moving the complete version directory on the same volume makes it
        // visible to the resolver only after verification has finished.
        try fm.moveItem(at: stagedVersion, to: installedVersion)
    } catch {
        if fm.fileExists(atPath: replacedVersion.path), !fm.fileExists(atPath: installedVersion.path) {
            try? fm.moveItem(at: replacedVersion, to: installedVersion)
        }
        throw error
    }

    removeQuarantineRecursively(at: installedApp)
    if fm.fileExists(atPath: replacedVersion.path) {
        do {
            try fm.removeItem(at: replacedVersion)
        } catch {
            log("launcher", "Warning: could not remove the replaced Helium directory: \(error.localizedDescription)")
        }
    }
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
