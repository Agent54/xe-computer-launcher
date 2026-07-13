import AppKit

/// Handles the one-time handoff from a read-only distribution disk image to an
/// installed copy. Declining installation deliberately has no lasting effect so
/// builds can still be run and tested directly from a DMG.
@MainActor
enum ApplicationInstaller {
    private enum InstallResult {
        case installed(URL)
        case declined
        case failed(Error)
    }

    /// Returns `true` while this instance is waiting for the installed copy to
    /// launch. The caller should defer its normal startup in that case.
    static func handleDiskImageLaunch(
        onRelaunchFailure: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard isRunningFromDiskImage() else { return false }

        NSApp.activate(ignoringOtherApps: true)

        let installAlert = NSAlert()
        installAlert.alertStyle = .informational
        installAlert.messageText = "Install Darc Launcher?"
        installAlert.informativeText = "Darc Launcher is running from a disk image. Would you like to copy it to the Applications folder and reopen it from there?"
        installAlert.addButton(withTitle: "Install in Applications")
        installAlert.addButton(withTitle: "Run from Disk Image")

        guard installAlert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        switch install(in: systemApplications) {
        case .installed(let destination):
            relaunchInstalledCopy(at: destination, onFailure: onRelaunchFailure)
            return true
        case .declined:
            return false
        case .failed(let error) where isPermissionError(error):
            return handleSystemApplicationsPermissionFailure(onRelaunchFailure: onRelaunchFailure)
        case .failed(let error):
            showInstallationFailure(error)
            return false
        }
    }

    /// Disk images created for distribution are mounted read-only under
    /// `/Volumes`. Quarantined apps may instead be launched from a read-only App
    /// Translocation mount, so that location is recognized as well. The volume
    /// flags cover equivalent read-only removable/ejectable media.
    static func isRunningFromDiskImage(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        let resolvedURL = bundleURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .volumeIsReadOnlyKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey
        ]

        guard let values = try? resolvedURL.resourceValues(forKeys: keys),
              values.volumeIsReadOnly == true else {
            return false
        }

        let path = resolvedURL.path
        return path.hasPrefix("/Volumes/")
            || path.contains("/AppTranslocation/")
            || values.volumeIsEjectable == true
            || values.volumeIsRemovable == true
    }

    private static func handleSystemApplicationsPermissionFailure(
        onRelaunchFailure: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        let fallbackAlert = NSAlert()
        fallbackAlert.alertStyle = .warning
        fallbackAlert.messageText = "Applications Folder Requires Permission"
        fallbackAlert.informativeText = "macOS did not allow Darc Launcher to write to /Applications. Would you like to install it in your personal Applications folder instead?"
        fallbackAlert.addButton(withTitle: "Install for This User")
        fallbackAlert.addButton(withTitle: "Run from Disk Image")

        guard fallbackAlert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)

        switch install(in: userApplications) {
        case .installed(let destination):
            relaunchInstalledCopy(at: destination, onFailure: onRelaunchFailure)
            return true
        case .declined:
            return false
        case .failed(let error):
            showInstallationFailure(error)
            return false
        }
    }

    private static func install(in applicationsDirectory: URL) -> InstallResult {
        let destination = applicationsDirectory.appendingPathComponent(
            installedBundleName,
            isDirectory: true
        )

        if FileManager.default.fileExists(atPath: destination.path),
           !confirmReplacement(at: destination) {
            return .declined
        }

        do {
            return .installed(try copyCurrentBundle(to: destination))
        } catch {
            return .failed(error)
        }
    }

    private static func confirmReplacement(at destination: URL) -> Bool {
        let installedVersion = versionDescription(forBundleAt: destination) ?? "an unknown version"
        let candidateVersion = versionDescription(forBundleAt: Bundle.main.bundleURL) ?? "this version"

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace Installed Darc Launcher?"
        alert.informativeText = "Darc Launcher \(installedVersion) is already installed at \(destination.path). Replace it with \(candidateVersion)?"
        alert.addButton(withTitle: "Replace and Relaunch")
        alert.addButton(withTitle: "Run from Disk Image")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func copyCurrentBundle(to destination: URL) throws -> URL {
        let fileManager = FileManager.default
        let applicationsDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: applicationsDirectory,
            withIntermediateDirectories: true
        )

        // Finish the potentially long copy before touching an existing install.
        // Keeping the staging item on the destination volume also lets the final
        // move or replacement complete as a single local filesystem operation.
        let stagingURL = applicationsDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).installing-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try fileManager.copyItem(at: Bundle.main.bundleURL, to: stagingURL)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagingURL, to: destination)
        }

        return destination
    }

    private static func relaunchInstalledCopy(
        at destination: URL,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false

        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { application, error in
            let expectedURL = destination.resolvingSymlinksInPath().standardizedFileURL
            let launchedURL = application?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
            let didLaunch = error == nil && launchedURL == expectedURL
            let failureMessage: String
            if let error {
                failureMessage = error.localizedDescription
            } else if let launchedURL {
                failureMessage = "macOS opened \(launchedURL.path) instead of the installed copy."
            } else {
                failureMessage = "macOS did not return a running application."
            }

            Task { @MainActor in
                if didLaunch {
                    // Only terminate after Launch Services confirms that the exact
                    // installed URL has started as a new application instance.
                    NSApp.terminate(nil)
                    return
                }

                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Installed, but Couldn’t Relaunch"
                alert.informativeText = "Darc Launcher was copied to \(destination.path), but macOS could not start it:\n\n\(failureMessage)\n\nThis copy will continue running from the disk image."
                alert.addButton(withTitle: "Continue")
                alert.runModal()
                onFailure()
            }
        }
    }

    private static var installedBundleName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fallback = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return "\(name ?? fallback).app"
    }

    private static func versionDescription(forBundleAt url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)):
            return "version \(version) (build \(build))"
        case let (.some(version), .none):
            return "version \(version)"
        case let (.none, .some(build)):
            return "build \(build)"
        case (.none, .none):
            return nil
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteNoPermission.rawValue {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlyingError)
        }
        return false
    }

    private static func showInstallationFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Installation Failed"
        alert.informativeText = "Darc Launcher could not be installed:\n\n\(error.localizedDescription)\n\nIt will continue running from the disk image."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }
}
