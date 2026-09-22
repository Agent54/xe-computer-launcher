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
    trustedWebBundleID: String = trustedXeComputerWebBundleID
) -> DarcProfileBundleActivation? {
    guard let sourceData = try? Data(contentsOf: sourceURL, options: .mappedIfSafe),
          darcManifestVersion(in: sourceData, webBundleID: trustedWebBundleID) == expectedVersion,
          let sourceSHA256 = try? sha256Hex(of: sourceURL) else {
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

/// Activates a downloaded Darc release in every matching Chromium profile.
/// Chromium owns the fixed `main.swbn` filename, while Xe Launcher owns the
/// versioned source file used as the activation authority.
func activateDarcBundle(
    sourceURL: URL,
    expectedVersion: String,
    dataURL: URL,
    profileNames: Set<String>? = nil,
    trustedWebBundleID: String = trustedXeComputerWebBundleID,
    log: (String) -> Void = { _ in }
) throws -> DarcBundleActivationSummary {
    let fm = FileManager.default
    guard fm.fileExists(atPath: sourceURL.path) else {
        throw DarcBundleActivationError(message: "Configured Xe Computer bundle is missing at \(sourceURL.path)")
    }

    let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
    guard sourceData.count >= 1_000 else {
        throw DarcBundleActivationError(message: "Configured Xe Computer bundle is too small")
    }
    guard containsWebBundleID(trustedWebBundleID, in: sourceData) else {
        throw DarcBundleActivationError(message: "Configured Xe Computer bundle has an unexpected Web Bundle ID")
    }
    guard darcManifestVersion(in: sourceData, webBundleID: trustedWebBundleID) == expectedVersion else {
        throw DarcBundleActivationError(
            message: "Configured Xe Computer bundle does not contain manifest version \(expectedVersion)"
        )
    }

    let sourceSHA256 = try sha256Hex(of: sourceURL)
    let candidates = installedDarcBundleCandidates(
        dataURL: dataURL,
        profileNames: profileNames,
        trustedWebBundleID: trustedWebBundleID
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
    trustedWebBundleID: String
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
            guard fm.isReadableFile(atPath: bundleURL.path),
                  let data = try? Data(contentsOf: bundleURL, options: .mappedIfSafe),
                  darcManifestVersion(in: data, webBundleID: trustedWebBundleID) != nil else {
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

    guard Darwin.rename(stagedURL.path, destinationURL.path) == 0 else {
        let errorCode = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSLocalizedDescriptionKey: "Atomic Xe Computer bundle replacement failed"]
        )
    }
}

private func containsWebBundleID(_ webBundleID: String, in data: Data) -> Bool {
    let marker = Data("isolated-app://\(webBundleID)/".utf8)
    return data.range(of: marker) != nil
}

private func darcManifestVersion(in data: Data, webBundleID: String) -> String? {
    let manifestURL = Data(
        "isolated-app://\(webBundleID)/.well-known/manifest.webmanifest".utf8
    )
    var searchStart = data.startIndex

    while searchStart < data.endIndex,
          let manifestRange = data.range(of: manifestURL, in: searchStart..<data.endIndex) {
        // The signed bundle index contains the manifest URL shortly before the
        // manifest response. Limit parsing to that response neighborhood so a
        // JavaScript dependency's unrelated `version` field cannot satisfy the
        // release pin check.
        let windowEnd = min(data.endIndex, manifestRange.upperBound + 1_048_576)
        let manifestNeighborhood = Data(data[manifestRange.lowerBound..<windowEnd])
        if jsonStringValues(forKey: "name", in: manifestNeighborhood).contains("Xe Computer"),
           let version = jsonStringValues(forKey: "version", in: manifestNeighborhood).first(where: { value in
               let components = value.split(separator: ".", omittingEmptySubsequences: false)
               return components.count == 3 && components.allSatisfy { component in
                   !component.isEmpty && component.allSatisfy(\.isNumber)
               }
           }) {
            return version
        }
        searchStart = manifestRange.upperBound
    }
    return nil
}

private func jsonStringValues(forKey key: String, in data: Data) -> [String] {
    let keyData = Data("\"\(key)\"".utf8)
    let whitespace = Set<UInt8>([9, 10, 13, 32])
    var values: [String] = []
    var searchStart = data.startIndex

    while searchStart < data.endIndex,
          let keyRange = data.range(of: keyData, in: searchStart..<data.endIndex) {
        var index = keyRange.upperBound
        while index < data.endIndex && whitespace.contains(data[index]) { index += 1 }
        guard index < data.endIndex, data[index] == 58 else {
            searchStart = keyRange.upperBound
            continue
        }
        index += 1
        while index < data.endIndex && whitespace.contains(data[index]) { index += 1 }
        guard index < data.endIndex, data[index] == 34 else {
            searchStart = keyRange.upperBound
            continue
        }
        index += 1
        let valueStart = index
        guard let valueEnd = data[index..<data.endIndex].firstIndex(of: 34) else { break }
        if let value = String(data: data[valueStart..<valueEnd], encoding: .utf8) {
            values.append(value)
        }
        searchStart = data.index(after: valueEnd)
    }
    return values
}

private func relativePath(of url: URL, under root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
}
