import Foundation
import Darwin

let trustedXeComputerWebBundleID = "cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic"

struct DarcProfileBundleActivation: Equatable, Sendable {
    let profileName: String
    let version: String
    let sha256: String
    let webBundleID: String
    let relativeBundlePath: String
}

struct DarcBundleActivationSummary: Equatable {
    var activatedProfiles: [String] = []
    var verifiedProfiles: [String] = []
    var failedProfiles: [String] = []
}

struct DarcBundleActivationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Derives the effective activation directly from the pinned source and the
/// profile-owned bundle. No launcher state file participates in this result.
func activeDarcBundleActivation(
    dataURL: URL,
    profileName: String,
    sourceURL: URL,
    expectedVersion: String,
    expectedSHA256: String,
    trustedWebBundleID: String = trustedXeComputerWebBundleID
) -> DarcProfileBundleActivation? {
    guard let sourceSHA256 = try? sha256Hex(of: sourceURL), sourceSHA256 == expectedSHA256 else {
        return nil
    }

    let candidates = installedDarcBundleCandidates(
        dataURL: dataURL,
        profileNames: [profileName],
        trustedWebBundleID: trustedWebBundleID
    )
    for candidate in candidates {
        guard let installedSHA256 = try? sha256Hex(of: candidate.bundleURL),
              installedSHA256 == sourceSHA256 else { continue }
        return DarcProfileBundleActivation(
            profileName: profileName,
            version: expectedVersion,
            sha256: sourceSHA256,
            webBundleID: trustedWebBundleID,
            relativeBundlePath: relativePath(of: candidate.bundleURL, under: dataURL)
        )
    }
    return nil
}

func cachedDarcSource(at url: URL, expectedSHA256: String,
                      onInvalid: (Error) -> Void = { _ in }) -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
        try verifySourceChecksum(at: url, expectedSHA256: expectedSHA256)
        return url
    } catch {
        onInvalid(error)
        do { try FileManager.default.removeItem(at: url) }
        catch { onInvalid(error) }
        return nil
    }
}

func installDarcSource(from download: URL, at destination: URL, expectedSHA256: String) throws {
    try verifySourceChecksum(at: download, expectedSHA256: expectedSHA256)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try publishDarcBundle(from: download, to: destination)
}

/// Activates a downloaded Darc release in every matching Chromium profile.
/// Chromium owns the fixed `main.swbn` filename, while Xe Launcher owns the
/// versioned source file used as the activation authority.
func activateDarcBundle(
    sourceURL: URL,
    expectedVersion: String,
    expectedSHA256: String,
    dataURL: URL,
    profileNames: Set<String>? = nil,
    trustedWebBundleID: String = trustedXeComputerWebBundleID,
    log: (String) -> Void = { _ in }
) throws -> DarcBundleActivationSummary {
    try verifySourceChecksum(at: sourceURL, expectedSHA256: expectedSHA256)
    let sourceSHA256 = expectedSHA256
    let candidates = installedDarcBundleCandidates(
        dataURL: dataURL,
        profileNames: profileNames,
        trustedWebBundleID: trustedWebBundleID,
        log: log
    )
    var summary = DarcBundleActivationSummary()

    for candidate in candidates {
        do {
            let existingSHA256 = try sha256Hex(of: candidate.bundleURL)
            let bundleWasReplaced = existingSHA256 != sourceSHA256
            if bundleWasReplaced {
                try atomicallyReplaceDarcBundle(
                    at: candidate.bundleURL,
                    with: sourceURL,
                    expectedSHA256: sourceSHA256
                )
                appendUnique(candidate.profileName, to: &summary.activatedProfiles)
                log(
                    "Activated Xe Computer \(expectedVersion) for profile \(candidate.profileName) "
                        + "(SHA-256 \(sourceSHA256))"
                )
            } else {
                appendUnique(candidate.profileName, to: &summary.verifiedProfiles)
                log(
                    "Verified active Xe Computer \(expectedVersion) for profile \(candidate.profileName) "
                        + "(SHA-256 \(sourceSHA256))"
                )
            }

        } catch {
            appendUnique(candidate.profileName, to: &summary.failedProfiles)
            log("Could not activate Xe Computer for profile \(candidate.profileName): \(error.localizedDescription)")
        }
    }

    return summary
}

private struct InstalledDarcBundleCandidate {
    let profileName: String
    let bundleURL: URL
}

private func installedDarcBundleCandidates(
    dataURL: URL,
    profileNames: Set<String>?,
    trustedWebBundleID: String,
    log: (String) -> Void = { _ in }
) -> [InstalledDarcBundleCandidate] {
    let fm = FileManager.default
    let profilesRoot = dataURL.appendingPathComponent("profiles", isDirectory: true)
    guard let profileDirectories = try? fm.contentsOfDirectory(
        at: profilesRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var candidates: [InstalledDarcBundleCandidate] = []
    for profileDirectory in profileDirectories {
        let profileName = profileDirectory.lastPathComponent
        if let profileNames, !profileNames.contains(profileName) { continue }

        let iwaRoot = profileDirectory
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("iwa", isDirectory: true)
        guard let installedDirectories = try? fm.contentsOfDirectory(
            at: iwaRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            continue
        }

        for installedDirectory in installedDirectories {
            let bundleURL = installedDirectory.appendingPathComponent("main.swbn")
            // This marker identifies the target slot; it does not validate the
            // artifact. Only the pinned checksum authorizes published bytes.
            let marker = Data("webBundleId".utf8) + Data([0x78, UInt8(trustedWebBundleID.utf8.count)]) + Data(trustedWebBundleID.utf8)
            guard let handle = try? FileHandle(forReadingFrom: bundleURL) else { continue }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 1024), header.range(of: marker) != nil else {
                continue
            }
            candidates.append(InstalledDarcBundleCandidate(
                profileName: profileName,
                bundleURL: bundleURL
            ))
        }
    }
    return candidates
}

private func appendUnique(_ value: String, to values: inout [String]) {
    if !values.contains(value) {
        values.append(value)
    }
}

private func atomicallyReplaceDarcBundle(
    at destinationURL: URL,
    with sourceURL: URL,
    expectedSHA256: String
) throws {
    let fm = FileManager.default
    let stagedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
        ".main.swbn.update-\(UUID().uuidString)"
    )
    defer { try? fm.removeItem(at: stagedURL) }

    try fm.copyItem(at: sourceURL, to: stagedURL)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
    let stagedSHA256 = try sha256Hex(of: stagedURL)
    guard stagedSHA256 == expectedSHA256 else {
        throw DarcBundleActivationError(message: "Staged Xe Computer bundle failed SHA-256 verification")
    }

    let handle = try FileHandle(forWritingTo: stagedURL)
    try handle.synchronize()
    try handle.close()

    try publishDarcBundle(from: stagedURL, to: destinationURL)
}

private func publishDarcBundle(from stagedURL: URL, to destinationURL: URL) throws {
    guard Darwin.rename(stagedURL.path, destinationURL.path) == 0 else {
        let errorCode = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSLocalizedDescriptionKey: "Atomic Xe Computer bundle replacement failed"]
        )
    }
}

private func relativePath(of url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
}
