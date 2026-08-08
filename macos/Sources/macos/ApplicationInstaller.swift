import AppKit

/// Handles the one-time handoff from a read-only distribution disk image to an
/// installed copy. Declining installation deliberately has no lasting effect so
/// builds can still be run and tested directly from a DMG.
@MainActor
enum ApplicationInstaller {
    private static let installedRelaunchArgument = "--xe-computer-installed-relaunch"
    private static let developmentInstallArgument = "--xe-computer-development-install"
    private static var handoffInProgress = false

    private enum InstallResult {
        case installed(URL)
        case declined
        case failed(Error)
    }

    private enum InstallerError: LocalizedError {
        case couldNotStopExistingInstances([pid_t])

        var errorDescription: String? {
            switch self {
            case .couldNotStopExistingInstances(let processIdentifiers):
                let identifiers = processIdentifiers.map(String.init).joined(separator: ", ")
                return "The existing Xe Launcher instance could not be stopped (process \(identifiers)). Quit it manually and try again."
            }
        }
    }

    /// Returns `true` while this instance is waiting for the installed copy to
    /// launch. The caller should defer its normal startup in that case.
    static func handleDiskImageLaunch(
        onContinueFromDiskImage: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        // The first launch of the installed copy may still be translocated while
        // Launch Services refreshes its quarantine state. It was launched from
        // the destination URL by this installer, so it must not install again.
        guard !ProcessInfo.processInfo.arguments.contains(installedRelaunchArgument) else {
            return false
        }
        guard isRunningFromDiskImage() else { return false }
        guard !handoffInProgress else { return true }

        NSApp.activate(ignoringOtherApps: true)

        let installAlert = NSAlert()
        installAlert.alertStyle = .informational
        installAlert.messageText = "Install Xe Launcher?"
        installAlert.informativeText = "Xe Launcher is running from a disk image. Would you like to copy it to the Applications folder and reopen it from there?"
        installAlert.addButton(withTitle: "Install in Applications")
        installAlert.addButton(withTitle: "Run from Disk Image")

        guard installAlert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        handoffInProgress = true
        Task { @MainActor in
            await performInstallationFlow(onContinueFromDiskImage: onContinueFromDiskImage)
        }
        return true
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

    private static func performInstallationFlow(
        onContinueFromDiskImage: @escaping @MainActor @Sendable () -> Void
    ) async {
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let systemResult = await install(in: systemApplications)

        switch systemResult {
        case .installed(let destination):
            relaunchInstalledCopy(at: destination) {
                continueFromDiskImage(onContinueFromDiskImage)
            }
        case .declined:
            continueFromDiskImage(onContinueFromDiskImage)
        case .failed(let error) where isPermissionError(error):
            let userResult = await offerCurrentUserInstallation()
            switch userResult {
            case .installed(let destination):
                relaunchInstalledCopy(at: destination) {
                    continueFromDiskImage(onContinueFromDiskImage)
                }
            case .declined:
                continueFromDiskImage(onContinueFromDiskImage)
            case .failed(let error):
                showInstallationFailure(error)
                continueFromDiskImage(onContinueFromDiskImage)
            }
        case .failed(let error):
            showInstallationFailure(error)
            continueFromDiskImage(onContinueFromDiskImage)
        }
    }

    private static func offerCurrentUserInstallation() async -> InstallResult {
        let fallbackAlert = NSAlert()
        fallbackAlert.alertStyle = .warning
        fallbackAlert.messageText = "Applications Folder Requires Permission"
        fallbackAlert.informativeText = "macOS did not allow Xe Launcher to write to /Applications. Would you like to install it in your personal Applications folder instead?"
        fallbackAlert.addButton(withTitle: "Install for This User")
        fallbackAlert.addButton(withTitle: "Run from Disk Image")

        guard fallbackAlert.runModal() == .alertFirstButtonReturn else {
            return .declined
        }

        let userApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)

        return await install(in: userApplications)
    }

    private static func install(in applicationsDirectory: URL) async -> InstallResult {
        let destination = applicationsDirectory.appendingPathComponent(
            installedBundleName,
            isDirectory: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            showExistingInstallation(at: destination)
            return .declined
        }

        do {
            return .installed(try await copyCurrentBundle(to: destination))
        } catch {
            return .failed(error)
        }
    }

    private static func showExistingInstallation(at destination: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Xe Launcher Is Already Installed"
        alert.informativeText = "An app already exists at \(destination.path). It will not be replaced. Remove it manually before installing this version, or continue running this copy from the disk image."
        alert.addButton(withTitle: "Run from Disk Image")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    private static func copyCurrentBundle(to destination: URL) async throws -> URL {
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

        // Copying preserves the download quarantine that caused the source app
        // to be translocated. The user explicitly approved this installation,
        // and Foundation provides this public API for removing that metadata.
        // Clearing it on the staged copy lets Launch Services run the installed
        // bundle from its real Applications path.
        var quarantineValues = URLResourceValues()
        quarantineValues.quarantineProperties = nil
        var mutableStagingURL = stagingURL
        try mutableStagingURL.setResourceValues(quarantineValues)

        // Launch Services may substitute any process with the same bundle ID,
        // so stop other launcher instances only after the new bundle is fully
        // staged. Existing destination bundles are never replaced.
        try await stopOtherRunningInstances()

        // Recheck immediately before the move to close the race between the
        // initial existence check and committing the staged bundle. moveItem
        // also refuses to overwrite if another process creates it afterward.
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        try fileManager.moveItem(at: stagingURL, to: destination)

        return destination
    }

    private static func otherRunningInstances() -> [NSRunningApplication] {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return [] }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != currentProcessIdentifier }
    }

    private static func stopOtherRunningInstances() async throws {
        let applications = otherRunningInstances()
        guard !applications.isEmpty else { return }

        for application in applications where !application.isTerminated {
            _ = application.terminate()
        }

        if await waitForTermination(of: applications, timeout: 5.0) {
            await waitForLaunchServicesToReleaseBundles()
            return
        }

        for application in applications where !application.isTerminated {
            _ = application.forceTerminate()
        }

        guard await waitForTermination(of: applications, timeout: 3.0) else {
            let processIdentifiers = applications
                .filter { !$0.isTerminated }
                .map(\.processIdentifier)
            throw InstallerError.couldNotStopExistingInstances(processIdentifiers)
        }

        await waitForLaunchServicesToReleaseBundles()
    }

    private static func waitForTermination(
        of applications: [NSRunningApplication],
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if applications.allSatisfy(\.isTerminated) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return applications.allSatisfy(\.isTerminated)
    }

    private static func waitForLaunchServicesToReleaseBundles() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private static func relaunchInstalledCopy(
        at destination: URL,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        if ProcessInfo.processInfo.arguments.contains(developmentInstallArgument) {
            // The integration runner first removes the quarantine inherited
            // from the DMG, then asks Launch Services to start the installed
            // app. Starting it here would race that cleanup and trigger a
            // Gatekeeper denial on ad-hoc-signed development builds.
            NSApp.terminate(nil)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = [installedRelaunchArgument]

        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { application, error in
            // A successful app may report an App Translocation URL rather than
            // the requested source URL. That is a normal Gatekeeper behavior,
            // not evidence that Launch Services opened the wrong app.
            let didLaunch = application != nil && error == nil
            let failureMessage = error?.localizedDescription
                ?? "macOS did not return a running application."

            Task { @MainActor in
                if didLaunch {
                    // Only terminate after Launch Services confirms that the exact
                    // installed URL has started as a new application instance.
                    NSApp.terminate(nil)
                    return
                }

                showRelaunchFailure(
                    at: destination,
                    message: failureMessage,
                    onFailure: onFailure
                )
            }
        }
    }

    private static func showRelaunchFailure(
        at destination: URL,
        message: String,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Installed, but Couldn’t Relaunch"
        alert.informativeText = "Xe Launcher was copied to \(destination.path), but macOS could not start it:\n\n\(message)\n\nThis copy will continue running from the disk image."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
        onFailure()
    }

    private static func continueFromDiskImage(
        _ continuation: @escaping @MainActor @Sendable () -> Void
    ) {
        handoffInProgress = false
        continuation()
    }

    private static var installedBundleName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fallback = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return "\(name ?? fallback).app"
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
        alert.informativeText = "Xe Launcher could not be installed:\n\n\(error.localizedDescription)\n\nIt will continue running from the disk image."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
    }
}
