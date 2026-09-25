import AppKit
import ApplicationServices
import CoreGraphics
import Sparkle

private enum LauncherUpdateChannel: String {
    case stable
    case int

    static func configured(in bundle: Bundle = .main) -> LauncherUpdateChannel {
        if let configuredValue = bundle.object(forInfoDictionaryKey: "XeUpdateChannel") as? String,
           let channel = LauncherUpdateChannel(rawValue: configuredValue) {
            return channel
        }

        // Preserve the correct channel for Sparkle-enabled builds released
        // before XeUpdateChannel was added to Info.plist.
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        return feedURL.contains("/updates/int/") ? .int : .stable
    }

    var displayName: String {
        switch self {
        case .stable: "Release (stable)"
        case .int: "Prerelease (int)"
        }
    }

    var feedURLString: String {
        "https://raw.githubusercontent.com/Agent54/xe-computer-launcher/updates/\(rawValue)/appcast.xml"
    }

}

private final class LauncherVersionDisplayer: NSObject, SUVersionDisplay {
    private let releaseVersion: String

    init(releaseVersion: String) {
        self.releaseVersion = releaseVersion
    }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = releaseVersion as NSString
        return update.displayVersionString
    }

    func formatBundleDisplayVersion(
        _ bundleDisplayVersion: String,
        withBundleVersion bundleVersion: String,
        matchingUpdate: SUAppcastItem?
    ) -> String {
        releaseVersion
    }
}

private final class LauncherUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private let versionDisplayer: LauncherVersionDisplayer

    init(releaseVersion: String) {
        versionDisplayer = LauncherVersionDisplayer(releaseVersion: releaseVersion)
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        versionDisplayer
    }
}

private enum ShutdownComponent: CaseIterable, Hashable {
    case containerVM
    case browserStack
    case hostServices

    var title: String {
        switch self {
        case .containerVM: "container VM"
        case .browserStack: "Xe Computer and browser"
        case .hostServices: "host services"
        }
    }
}

@main
struct MacOSApp {
    static func main() {
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--xe-accessibility-trust-probe" {
            exit(AXIsProcessTrusted() ? 0 : 1)
        }
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--unregister-port-helper" {
            if let warning = PrivilegedPortService.unregisterIfRegistered() {
                fputs("\(warning)\n", stderr)
                exit(1)
            }
            return
        }

        // Sandbox disabled during development
        // if !Sandbox.apply() {
        //     print("[FATAL] Sandbox failed to apply - refusing to run unsandboxed")
        //     exit(1)
        // }

        // Set CWD to app data folder
        let appDataPath = ExternalState.appDataFolder
        FileManager.default.changeCurrentDirectoryPath(appDataPath)
        print("[Init] CWD set to \(appDataPath)")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SPUUpdaterDelegate {
    private var didFinishNormalStartup = false
    private var setupDeferredOnThisLaunch = false
    private var isPreparingForTermination = false
    private var runtimeStartupTask: Task<Void, Never>?
    private var browserStartupTask: Task<Void, Never>?
    private var composeServer: ComposeServer?
    private var workerdServer = WorkerdServer()
    private let runtimeSupervisor = ContainerRuntimeSupervisor()
    private var hostServicesTask: Task<Void, Never>?
    private var composeSocketURL = ComposeServerPaths.stacksURL.appendingPathComponent("compose.sock")
    private var isWaitingForRuntimeShutdown = false
    private var terminationTimeoutTask: Task<Void, Never>?
    private var didReplyToTermination = false
    private var statusItem: NSStatusItem?
    private var statusMessageItem: NSMenuItem?
    private var shutdownProgressIndicator: NSProgressIndicator?
    private var pendingShutdownComponents = Set<ShutdownComponent>()
    private let updateChannel = LauncherUpdateChannel.configured()
    private let releaseVersion = Bundle.main.object(forInfoDictionaryKey: "XeReleaseVersion") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Unknown"
    private lazy var updaterUserDriverDelegate = LauncherUserDriverDelegate(releaseVersion: releaseVersion)
    private var isUpdaterConfigured: Bool {
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !publicKey.isEmpty && publicKey != "SPARKLE_PUBLIC_ED_KEY"
    }
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: updaterUserDriverDelegate
    )
    private var updateFeedCacheKey = UUID().uuidString
    private let logPanelController = LogPanelController()
    private var stateRefreshTimer: Timer?
    private var specialKeyCheck: Any?
    private var optionKeyTimer: Timer?
    private var lastOptionKeyState: Bool = false
    private var chromeVariantsScanned: Bool = false

    // Track which services have a pending operation (shows ⏳)
    private var pendingServices: Set<String> = []

    private var darcItem: NSMenuItem?
    private var darcStartItem: NSMenuItem?
    private var darcStopItem: NSMenuItem?
    private var chromeItem: NSMenuItem?
    private var chromeStartItem: NSMenuItem?
    private var chromeStopItem: NSMenuItem?
    private var chromeHeadlessItem: NSMenuItem?
    private var runAtStartupItem: NSMenuItem?
    private var bindCapslockItem: NSMenuItem?
    private var hideDockIconItem: NSMenuItem?
    private var saveWindowPositionsItem: NSMenuItem?
    private var restoreWindowPositionsItem: NSMenuItem?
    private var newProfileItem: NSMenuItem?
    private var systemLogsItem: NSMenuItem?
    private var openAppDataFolderItem: NSMenuItem?
    private var openAppDataFolderSeparator: NSMenuItem?
    private var advancedItemsSeparator: NSMenuItem?
    private var localAppPortsItem: NSMenuItem?
    private var composeStorageFolderItem: NSMenuItem?
    private var settingsRestartRequired = false
    private var updateChannelItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isWaitingForRelaunch = ApplicationInstaller.handleDiskImageLaunch(onContinueFromDiskImage: { [weak self] in
            self?.finishNormalStartup()
        })
        guard !isWaitingForRelaunch else { return }

        finishNormalStartup()
    }

    private func finishNormalStartup() {
        guard !didFinishNormalStartup else { return }
        didFinishNormalStartup = true

        // The DMG installer runs as an accessory app. Only normal launcher
        // startup owns a Dock icon, according to the user's saved preference.
        let state = ExternalState.shared
        state.updateSettings()
        configureApplicationIdentity()
        applyDockIconPreference()
        setupMainMenu()
        setupStatusItem()
        renderMenuLabels()

        // First-run setup and legacy settings without a port choice both need
        // a decision before Workerd starts, even without virtualization.
        let wasChoosingPorts = WorkerdPorts.needsPortChoice(state.settings.rawData)
        if LauncherSetup.needsChoice() {
            do {
                setupDeferredOnThisLaunch = try LauncherSetup.chooseIfNeeded() == nil
            } catch {
                setupDeferredOnThisLaunch = true
                state.appendLog("launcher", "Warning: launcher setup unavailable: \(error.localizedDescription)")
            }
        }
        if setupDeferredOnThisLaunch {
            state.appendLog("launcher", "Local app routing deferred until storage and port setup is complete.")
        }
        state.updateSettings()
        let workerdPorts = WorkerdPorts(settings: state.settings.rawData)
        workerdServer = WorkerdServer(routingPort: workerdPorts.http, tlsPort: workerdPorts.https)
        for warning in setupDeferredOnThisLaunch ? [] : workerdPorts.settingWarnings {
            state.appendLog("launcher", "Warning: \(warning)")
        }
        let needsPortHelper = workerdPorts.http == WorkerdPorts.standardHTTP
        if wasChoosingPorts && needsPortHelper && !setupDeferredOnThisLaunch {
            // The migration dialog has just closed. Keep setup visibly in
            // progress while macOS registers and activates the selected helper.
            showSetupProgress(message: "", placement: .topTrailing, allowsCancellation: false)
            updateSetupProgress(status: "Setting up ports 80/443. Approve Xe Launcher in System Settings if asked; setup will continue automatically.")
            setSetupProgressIndeterminate(true)
        }
        // Updating a copy on a read-only disk image cannot succeed. The copy
        // installed into /Applications or ~/Applications starts Sparkle on its
        // first normal launch instead.
        if isUpdaterConfigured && !ApplicationInstaller.isRunningFromDiskImage() {
            ExternalState.shared.appendLog(
                "launcher",
                "Sparkle update channel: \(updateChannel.displayName); feed=\(updateChannel.feedURLString)"
            )
            _ = updaterController
        }

        Task { @MainActor in
            let helperWarning = setupDeferredOnThisLaunch ? nil :
                (needsPortHelper ? await PrivilegedPortService.registerIfNeeded() :
                    PrivilegedPortService.unregisterIfRegistered())
            let bindingWarnings = setupDeferredOnThisLaunch ? [] :
                workerdPorts.bindingWarnings(skipStandardPorts: needsPortHelper)
            let portWarnings = bindingWarnings + (helperWarning.map { [$0] } ?? [])
            for warning in portWarnings {
                state.appendLog("launcher", "Warning: \(warning)")
            }
            var helperProgressVisible = wasChoosingPorts && needsPortHelper && !setupDeferredOnThisLaunch
            var nextHelperRecoveryAt = Date().addingTimeInterval(12)
            if needsPortHelper && helperWarning != nil && PrivilegedPortService.status != .enabled {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Port Helper Needs Attention"
                alert.informativeText = portWarnings.joined(separator: "\n")
                alert.alertStyle = .warning
                if !helperProgressVisible {
                    showSetupProgress(message: "", placement: .topTrailing, allowsCancellation: false)
                    setSetupProgressIndeterminate(true)
                    helperProgressVisible = true
                }
                setSetupProgressAction(title: "Open System Settings") {
                    PrivilegedPortService.openSystemSettings()
                }
                let needsApproval = PrivilegedPortService.status == .requiresApproval
                updateSetupProgress(status: needsApproval
                    ? "Enable Xe Launcher under Allow in Background in System Settings. Setup will continue automatically."
                    : "The port helper is not ready. Open System Settings or retry its registration.")
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: needsApproval ? "Wait for Approval" : "Try Again")
                alert.addButton(withTitle: "Not Now")
                let approvalTimer = Timer(timeInterval: 1, repeats: true) { _ in
                    if PrivilegedPortService.status == .enabled {
                        MainActor.assumeIsolated {
                            NSApp.stopModal(withCode: .alertSecondButtonReturn)
                        }
                    }
                }
                RunLoop.main.add(approvalTimer, forMode: .common)
                let response = alert.runModal()
                approvalTimer.invalidate()
                alert.window.orderOut(nil)
                if response == .alertFirstButtonReturn {
                    PrivilegedPortService.openSystemSettings()
                    nextHelperRecoveryAt = Date().addingTimeInterval(120)
                } else if response == .alertSecondButtonReturn {
                    if !needsApproval && PrivilegedPortService.status != .enabled {
                        if let retryWarning = await PrivilegedPortService.registerIfNeeded() {
                            state.appendLog("launcher", "Port helper retry: \(retryWarning)")
                        }
                    }
                    nextHelperRecoveryAt = Date().addingTimeInterval(needsApproval ? 120 : 20)
                } else {
                    closeSetupProgress()
                    return
                }
            } else if !bindingWarnings.isEmpty {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Local App Ports Are Unavailable"
                alert.informativeText = bindingWarnings.joined(separator: "\n") +
                    "\n\nFree occupied ports; Xe Launcher will retry automatically."
                alert.alertStyle = .warning
                alert.runModal()
            }

            // A Settings switch can report enabled before launchd has started
            // the daemon. Confirm the actual socket handoff before starting
            // Workerd or the browser on standard ports.
            if needsPortHelper && !setupDeferredOnThisLaunch {
                while !Task.isCancelled {
                    let helperStatus = PrivilegedPortService.status
                    var acquireFailure: String?
                    if helperStatus == .enabled {
                        do {
                            _ = try await PrivilegedPortService.acquire()
                            break
                        } catch {
                            acquireFailure = error.localizedDescription
                        }
                    }
                    if !helperProgressVisible {
                        showSetupProgress(message: "", placement: .topTrailing, allowsCancellation: false)
                        setSetupProgressIndeterminate(true)
                        helperProgressVisible = true
                    }
                    setSetupProgressAction(title: "Open System Settings") {
                        PrivilegedPortService.openSystemSettings()
                    }
                    updateSetupProgress(status: helperStatus == .enabled
                        ? "Xe Launcher is allowed in the background, but its port helper is not responding. Open System Settings or use Try Again when prompted."
                        : "Enable Xe Launcher under Allow in Background in System Settings. Enter your password if asked; setup will continue automatically.")
                    if Date() >= nextHelperRecoveryAt {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Port Helper Could Not Start"
                        alert.informativeText = (acquireFailure.map { "The helper did not respond: \($0)\n\n" } ?? "") +
                            (helperStatus == .enabled
                                ? "macOS already lists Xe Launcher as allowed in the background, but its port helper is not responding on ports 80/443. Choose Try Again to refresh the helper registration, or open System Settings to inspect its background switch."
                                : "Xe Launcher needs its background port helper for local apps on ports 80/443. Open System Settings → General → Login Items & Extensions and allow Xe Launcher, or retry registration.")
                        alert.addButton(withTitle: "Open System Settings")
                        alert.addButton(withTitle: "Try Again")
                        alert.addButton(withTitle: "Not Now")
                        NSApp.activate(ignoringOtherApps: true)
                        let response = alert.runModal()
                        alert.window.orderOut(nil)
                        if response == .alertFirstButtonReturn {
                            PrivilegedPortService.openSystemSettings()
                            nextHelperRecoveryAt = Date().addingTimeInterval(120)
                        } else if response == .alertSecondButtonReturn {
                            if let warning = await PrivilegedPortService.registerIfNeeded(forceRefresh: helperStatus == .enabled) {
                                state.appendLog("launcher", "Port helper retry: \(warning)")
                            }
                            nextHelperRecoveryAt = Date().addingTimeInterval(20)
                        } else {
                            closeSetupProgress()
                            return
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if Task.isCancelled {
                    closeSetupProgress()
                    return
                }
                if helperProgressVisible { closeSetupProgress() }
                state.appendLog("launcher", "Port helper ready; continuing launcher setup.")
            }

            // Keep the permission companion visible until macOS confirms both
            // approvals. Starting services sooner races the system dialogs and
            // lets a fresh installation appear ready before its ports are usable.
            guard await AccessibilityPermission.requestIfNeeded() else { return }
            if !setupDeferredOnThisLaunch {
                guard await requestLocalHTTPSTrustIfNeeded() else {
                    setupDeferredOnThisLaunch = true
                    state.appendLog("launcher", "Local HTTPS certificate approval deferred; browser startup will resume on the next launch.")
                    return
                }
            }
            if !setupDeferredOnThisLaunch { startHostServices() }
            if needsPortHelper && !setupDeferredOnThisLaunch {
                showSetupProgress(message: "", placement: .topTrailing, allowsCancellation: false)
                updateSetupProgress(status: "Starting local app routing on ports 80/443…")
                setSetupProgressIndeterminate(true)
                while !workerdServer.servingStandardPorts {
                    if Task.isCancelled {
                        closeSetupProgress()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                closeSetupProgress()
            }
            startBackgroundInitialization()
        }
    }

    private func requestLocalHTTPSTrustIfNeeded() async -> Bool {
        let stateURL = WorkerdPaths.stateURL
        while !Task.isCancelled {
            let certificateURL: URL
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try LocalTLSCertificate.prepare(stateURL: stateURL)
                }.value
                certificateURL = prepared.certificateURL
            } catch {
                if !retryLocalHTTPSTrust(after: "Xe Launcher could not create its local HTTPS certificate: \(error.localizedDescription)") {
                    return false
                }
                continue
            }

            let trusted = await Task.detached(priority: .userInitiated) {
                LocalHTTPSTrust.isTrusted(certificateURL: certificateURL)
            }.value
            if trusted { return true }

            showSetupProgress(
                message: "",
                placement: .topTrailing,
                allowsCancellation: false,
                title: "Trust Local HTTPS for Xe Launcher",
                minimumSize: NSSize(width: 540, height: 430)
            )
            updateSetupProgress(status: """
                Browsers need this trust to open Compose UI and local apps over HTTPS without certificate warnings. The certificate Xe Launcher serves covers compose-ui.localhost and *.app.localhost.

                Approving the macOS prompt trusts Xe Launcher's local CA for SSL in this user account, including other browsers. CA trust can apply to other domains it signs, not just those two local names.

                Enter your Mac password in the macOS prompt to continue.
                """)
            setSetupProgressIndeterminate(true)
            NSApp.activate(ignoringOtherApps: true)

            var installationError: Error?
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LocalHTTPSTrust.requestUserTrust(certificateURL: certificateURL)
                }.value
            } catch {
                installationError = error
            }
            // The security tool exits after authorization, but the new user
            // trust setting can take a moment to become visible to a separate
            // Security.framework evaluation.
            let trustDeadline = Date().addingTimeInterval(10)
            var nowTrusted = false
            repeat {
                nowTrusted = await Task.detached(priority: .userInitiated) {
                    LocalHTTPSTrust.isTrusted(certificateURL: certificateURL)
                }.value
                if nowTrusted || installationError != nil || Date() >= trustDeadline { break }
                try? await Task.sleep(for: .milliseconds(250))
            } while !Task.isCancelled
            closeSetupProgress()
            if nowTrusted {
                ExternalState.shared.appendLog("launcher", "Local HTTPS certificate trusted for this macOS user.")
                return true
            }
            let detail = installationError?.localizedDescription ??
                "macOS did not report the local HTTPS certificate as trusted."
            guard retryLocalHTTPSTrust(after: detail) else { return false }
        }
        return false
    }

    private func retryLocalHTTPSTrust(after detail: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Local HTTPS Certificate Needs Approval"
        alert.informativeText = detail +
            "\n\nXe Launcher serves HTTPS for compose-ui.localhost and *.app.localhost. The local CA is trusted for SSL in this macOS account and can sign for other domains. Choose Try Again to reopen the macOS approval prompt, or Not Now to retry on the next launch."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func startBackgroundInitialization() {
        guard !isPreparingForTermination, runtimeStartupTask == nil, browserStartupTask == nil else { return }
        guard !setupDeferredOnThisLaunch else {
            ExternalState.shared.appendLog("launcher", "Browser and container startup deferred until launcher setup is complete.")
            return
        }
        runtimeStartupTask = Task {
            do {
                // Host UI is already running, even on machines without a hypervisor.
                guard VirtualizationSupport.isAvailable else {
                    ExternalState.shared.appendLog("launcher", VirtualizationSupport.unavailableWarning)
                    return
                }
                guard let stacksURL = try LauncherSetup.chooseIfNeeded() else {
                    ExternalState.shared.appendLog("launcher", "Compose startup deferred until a user data folder is selected.")
                    return
                }
                try Task.checkCancellation()
                if composeServer == nil { composeServer = ComposeServer(stacksURL: stacksURL) }
                composeSocketURL = stacksURL.appendingPathComponent("compose.sock")
                // The host supervisor starts Compose without waiting for Docker.
                let result = try await runtimeSupervisor.start()
                ExternalState.shared.appendLog(
                    "launcher",
                    "SmolVM machine '\(result.machineName)' is running with Docker socket at \(result.dockerSocketURL.path)"
                )
                try Task.checkCancellation()
            } catch is CancellationError {
                // Quit or updater relaunch cancelled runtime startup.
            } catch {
                ExternalState.shared.appendLog(
                    "launcher",
                    "Warning: container services unavailable: \(error.localizedDescription). Xe Launcher will continue without container services."
                )
            }
        }

        browserStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = ExternalState.shared
            state.appendLog("launcher", "Recovering saved Xe Computer and browser state")
            let recoveredProcessCount = await Task.detached(priority: .userInitiated) {
                // Stop the managed browser before a pinned Helium update can
                // replace its application bundle.
                state.updateSettings()
                state.stopDarc()
                let staleProcesses = state.findZombieProcesses()
                state.killZombieProcesses(staleProcesses)
                state.updateAll()
                return staleProcesses.count
            }.value
            guard !Task.isCancelled else { return }

            if recoveredProcessCount > 0 {
                state.appendLog(
                    "launcher",
                    "Stopped \(recoveredProcessCount) browser process(es) left by an earlier launcher"
                )
            }
            state.appendLog("launcher", "Restoring saved Xe Computer and browser running state")

            let launchError = await Task.detached(priority: .userInitiated) {
                state.launchBrowserStack()
            }.value
            guard !Task.isCancelled else { return }
            if let launchError {
                state.appendLog("launcher", "Xe Computer state restoration failed: \(launchError)")
            }
            renderMenuLabels()
        }
    }

    private func startHostServices() {
        if let path = ExternalState.shared.stringSetting("compose_storage_path"), !path.isEmpty {
            composeSocketURL = URL(fileURLWithPath: path).appendingPathComponent("compose.sock")
            composeServer = ComposeServer(stacksURL: URL(fileURLWithPath: path))
        }
        hostServicesTask = Task {
            var activeComposeSocket: URL?
            var lastPortHelperRetry = Date.distantPast
            while !Task.isCancelled {
                if activeComposeSocket != composeSocketURL {
                    await workerdServer.stop()
                    activeComposeSocket = composeSocketURL
                }
                if workerdServer.usesStandardPorts && workerdServer.isRunning &&
                    !workerdServer.servingStandardPorts && PrivilegedPortService.status == .enabled &&
                    Date().timeIntervalSince(lastPortHelperRetry) >= 10 {
                    lastPortHelperRetry = Date()
                    ExternalState.shared.appendLog("launcher", "Port helper approved; restarting local app routing on 80/443")
                    await workerdServer.stop()
                }
                do {
                    try await workerdServer.start(composeSocketURL: composeSocketURL, routerSocketURL: SmolVMSetup.routerSocketURL)
                } catch is CancellationError { break }
                catch { ExternalState.shared.appendLog("workerd", error.localizedDescription) }
                renderMenuLabels()
                do { try await GuestRouter.shared.reconcile() }
                catch is CancellationError { break }
                catch { ExternalState.shared.appendLog("routing", error.localizedDescription) }
                await runtimeSupervisor.reconcile()
                if let composeServer {
                    do { try await composeServer.start(dockerSocketURL: SmolVMSetup.dockerSocketURL) }
                    catch is CancellationError { break }
                    catch { ExternalState.shared.appendLog("compose", error.localizedDescription) }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening a running app shim sends it the macOS reopen event. Merely
        // activating a windowless shim does not create or restore a window.
        let state = ExternalState.shared
        DispatchQueue.global(qos: .userInitiated).async {
            if let error = state.reopenDarc() {
                state.appendLog("launcher", "Xe Computer reopen failed: \(error)")
            }
            Task { @MainActor in self.renderMenuLabels() }
        }
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        renderMenuLabels()
        updateOptionOnlyMenuItems(optionHeld: isOptionKeyHeld)

        // The Dock appends its own native Quit command. Return a snapshot of
        // the status menu without our duplicate Quit item.
        guard let statusMenu = statusItem?.menu,
              let dockMenu = statusMenu.copy() as? NSMenu else {
            return nil
        }
        dockMenu.delegate = nil
        if let quitItem = dockMenu.items.first(where: { $0.action == #selector(quitAction) }) {
            dockMenu.removeItem(quitItem)
        }
        return dockMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        prepareForTermination()
        stopStateRefreshLoop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sparkle sends the application a regular terminate request before it
        // atomically replaces and relaunches the bundle. Keep this cleanup in
        // the delegate so updater-triggered termination and the Quit menu item
        // have identical service-state behavior.
        prepareForTermination()
        guard didFinishNormalStartup else { return .terminateNow }

        if !isWaitingForRuntimeShutdown {
            isWaitingForRuntimeShutdown = true
            let shutdownStartedAt = Date()
            ExternalState.shared.appendLog("launcher", "Shutdown started")

            let vmCleanup = Task { @MainActor in
                let phaseStartedAt = Date()
                defer { shutdownComponentFinished(.containerVM) }
                ExternalState.shared.appendLog("launcher", "Stopping SmolVM")
                do {
                    try await runtimeSupervisor.stop()
                    ExternalState.shared.appendLog(
                        "launcher",
                        "SmolVM machine '\(SmolVMSetup.machineName)' stopped in \(Self.elapsedDescription(since: phaseStartedAt))"
                    )
                } catch is CancellationError {
                    ExternalState.shared.appendLog(
                        "launcher",
                        "SmolVM shutdown cancelled after \(Self.elapsedDescription(since: phaseStartedAt))"
                    )
                } catch {
                    ExternalState.shared.appendLog(
                        "launcher",
                        "Warning: could not stop SmolVM machine '\(SmolVMSetup.machineName)' after \(Self.elapsedDescription(since: phaseStartedAt)): \(error.localizedDescription)"
                    )
                }
            }

            let browserCleanup = Task { @MainActor in
                let phaseStartedAt = Date()
                defer { shutdownComponentFinished(.browserStack) }
                ExternalState.shared.appendLog("launcher", "Stopping Xe Computer and browser")
                await Task.detached(priority: .userInitiated) {
                    let state = ExternalState.shared
                    state.stopDarc()
                    state.stopChrome()
                }.value
                ExternalState.shared.appendLog(
                    "launcher",
                    "Xe Computer and browser stopped in \(Self.elapsedDescription(since: phaseStartedAt))"
                )
            }

            let hostCleanup = Task { @MainActor in
                let phaseStartedAt = Date()
                defer { shutdownComponentFinished(.hostServices) }
                ExternalState.shared.appendLog("launcher", "Stopping host services")
                let workerdCleanup = Task { @MainActor in await workerdServer.stop() }
                let composeCleanup = Task { @MainActor in await composeServer?.stop() }
                await workerdCleanup.value
                await composeCleanup.value
                // Keep launchd registration across quit/relaunch so an approved
                // standard-port helper stays available. Startup unregisters it
                // when the configured ports switch away from 80/443.
                ExternalState.shared.appendLog(
                    "launcher",
                    "Host services stopped in \(Self.elapsedDescription(since: phaseStartedAt))"
                )
            }

            terminationTimeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                ExternalState.shared.appendLog(
                    "launcher",
                    "Shutdown exceeded 60 seconds; terminating after forced process cleanup"
                )
                vmCleanup.cancel()
                browserCleanup.cancel()
                hostCleanup.cancel()
                finishTermination(sender)
            }

            Task {
                await vmCleanup.value
                await browserCleanup.value
                await hostCleanup.value
                ExternalState.shared.appendLog(
                    "launcher",
                    "Shutdown complete in \(Self.elapsedDescription(since: shutdownStartedAt))"
                )
                finishTermination(sender)
            }
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        terminationTimeoutTask?.cancel()
        sender.reply(toApplicationShouldTerminate: true)
    }

    private static func elapsedDescription(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private func prepareForTermination() {
        guard !isPreparingForTermination, didFinishNormalStartup else { return }
        isPreparingForTermination = true
        beginShutdownPresentation()
        runtimeStartupTask?.cancel()
        browserStartupTask?.cancel()
        hostServicesTask?.cancel()
        workerdServer.requestStop()
        composeServer?.requestStop()

        ExternalState.shared.requestBrowserStackStop()
    }

    private func beginShutdownPresentation() {
        pendingShutdownComponents = Set(ShutdownComponent.allCases)
        updateShutdownStatus()
        if let menu = statusItem?.menu {
            disableMenuItemsForShutdown(in: menu)
            menu.update()
        }

        guard shutdownProgressIndicator == nil, let button = statusItem?.button else { return }
        statusItem?.length = NSStatusItem.squareLength
        button.image = nil
        button.toolTip = "Xe Launcher is shutting down"

        let indicator = NSProgressIndicator(frame: NSRect(x: 4, y: 4, width: 14, height: 14))
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        button.addSubview(indicator)
        indicator.startAnimation(nil)
        shutdownProgressIndicator = indicator
    }

    private func shutdownComponentFinished(_ component: ShutdownComponent) {
        pendingShutdownComponents.remove(component)
        updateShutdownStatus()
    }

    private func updateShutdownStatus() {
        let pending = ShutdownComponent.allCases.filter { pendingShutdownComponents.contains($0) }
        let detail: String
        switch pending.count {
        case 0:
            detail = "Finishing shutdown…"
        case 1:
            detail = "Stopping \(pending[0].title)…"
        default:
            detail = "Stopping " + pending.map(\.title).joined(separator: ", ") + "…"
        }
        statusMessageItem?.title = "Status: \(detail)"
        statusItem?.menu?.update()
    }

    private func disableMenuItemsForShutdown(in menu: NSMenu) {
        for item in menu.items {
            if item !== statusMessageItem && !item.isSeparatorItem {
                item.isEnabled = false
            }
            if let submenu = item.submenu {
                disableMenuItemsForShutdown(in: submenu)
            }
        }
    }

    /// Create a minimal main menu so keyboard shortcuts (Cmd+C, Cmd+A, etc.)
    /// work in panels like the log viewer even though this is an LSUIElement app.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.setAccessibilityIdentifier("dev.xe.computer.status-menu")
            button.setAccessibilityLabel("Xe Launcher status menu")
            button.toolTip = "Xe Launcher"

            if let resourceURL = Bundle.main.resourceURL,
               let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("status-icon.png")) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(
                    systemSymbolName: "desktopcomputer",
                    accessibilityDescription: "Xe Launcher"
                )
                button.image?.size = NSSize(width: 18, height: 18)
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let statusMessageItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        menu.addItem(statusMessageItem)
        self.statusMessageItem = statusMessageItem
        menu.addItem(.separator())

        // Profile entries are inserted dynamically between here and the New Profile item
        profileInsertionIndex = menu.numberOfItems
        rebuildProfileItems()

        let newProfileItem = NSMenuItem(title: "New Profile...", action: #selector(newProfileAction), keyEquivalent: "")
        newProfileItem.target = self
        newProfileItem.isHidden = true
        menu.addItem(newProfileItem)
        self.newProfileItem = newProfileItem

        let advancedSeparator = NSMenuItem.separator()
        advancedSeparator.isHidden = true
        menu.addItem(advancedSeparator)
        advancedItemsSeparator = advancedSeparator
        let saveWindowPositionsItem = NSMenuItem(title: "Save Window Positions", action: #selector(darcSaveWindowPositionsAction), keyEquivalent: "")
        saveWindowPositionsItem.isHidden = true
        menu.addItem(saveWindowPositionsItem)
        self.saveWindowPositionsItem = saveWindowPositionsItem
        let restoreWindowPositionsItem = NSMenuItem(title: "Restore Window Positions", action: #selector(darcRestoreWindowPositionsAction), keyEquivalent: "")
        restoreWindowPositionsItem.isHidden = true
        menu.addItem(restoreWindowPositionsItem)
        self.restoreWindowPositionsItem = restoreWindowPositionsItem
        let systemLogsItem = NSMenuItem(title: "System Logs", action: #selector(showLogsAction), keyEquivalent: "")
        systemLogsItem.isHidden = true
        menu.addItem(systemLogsItem)
        self.systemLogsItem = systemLogsItem

        let appDataSeparator = NSMenuItem.separator()
        appDataSeparator.isHidden = true
        menu.addItem(appDataSeparator)
        openAppDataFolderSeparator = appDataSeparator

        let appDataItem = NSMenuItem(title: "Open App Data Folder", action: #selector(openAppDataFolderAction), keyEquivalent: "")
        appDataItem.isHidden = true
        menu.addItem(appDataItem)
        openAppDataFolderItem = appDataItem

        let portsItem = NSMenuItem(title: "Local App Ports…", action: #selector(changeLocalAppPortsAction), keyEquivalent: "")
        portsItem.isHidden = true
        menu.addItem(portsItem)
        localAppPortsItem = portsItem
        let storageFolderItem = NSMenuItem(title: "Compose Storage Folder…", action: #selector(changeStorageFolderAction), keyEquivalent: "")
        storageFolderItem.isHidden = true
        menu.addItem(storageFolderItem)
        composeStorageFolderItem = storageFolderItem

        menu.addItem(.separator())

        runAtStartupItem = NSMenuItem(title: "Run at Startup", action: #selector(runAtStartupAction), keyEquivalent: "")
        bindCapslockItem = NSMenuItem(title: "Bind to Caps Lock", action: #selector(bindCapslockAction), keyEquivalent: "")
        hideDockIconItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(hideDockIconAction), keyEquivalent: "")
        if let runAtStartupItem { menu.addItem(runAtStartupItem) }
        if let bindCapslockItem { menu.addItem(bindCapslockItem) }
        if let hideDockIconItem { menu.addItem(hideDockIconItem) }

        menu.addItem(.separator())
        let updateChannelItem = NSMenuItem(
            title: "Update Channel: \(updateChannel.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        updateChannelItem.isEnabled = false
        updateChannelItem.isHidden = true
        menu.addItem(updateChannelItem)
        self.updateChannelItem = updateChannelItem
        let updateTitle = updateChannel == .int ? "Update (int)" : "Check for Updates…"
        let checkForUpdatesItem = NSMenuItem(
            title: updateTitle,
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        menu.addItem(checkForUpdatesItem)
        self.checkForUpdatesItem = checkForUpdatesItem
        menu.addItem(NSMenuItem(title: "About", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))

        setTargets(for: menu)
        statusItem?.menu = menu
    }

    private var chromeVariantItems: [NSMenuItem] = []
    private var chromeSubmenu: NSMenu?



    private var chromeVariantSeparator: NSMenuItem?

    /// Read modifier state for the whole login session. Dock-menu requests are
    /// delivered across processes and do not necessarily have a current NSEvent
    /// in this app, unlike clicks on the status item.
    private var isOptionKeyHeld: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
    }

    private func refreshChromeMenuOptions(in submenu: NSMenu) {
        // Remove old variant items
        for old in chromeVariantItems { submenu.removeItem(old) }
        chromeVariantItems.removeAll()
        if let sep = chromeVariantSeparator { submenu.removeItem(sep); chromeVariantSeparator = nil }

        let state = ExternalState.shared
        let minVersion = 145
        let showVariants = isOptionKeyHeld

        // Only scan all Chrome variants once when Option key is first pressed
        if showVariants && !chromeVariantsScanned {
            state.refreshChromeAvailability(scanAll: true)
            chromeVariantsScanned = true
        }
        let selected = state.selectedChrome()

        // Only show variant selector when Option key is held
        guard showVariants else { return }

        let sep = NSMenuItem.separator()
        submenu.addItem(sep)
        chromeVariantSeparator = sep

        for chrome in state.installedChromes where chrome.isInstalled && (chrome.version ?? 0) >= minVersion {
            let versionStr = chrome.version.map { " (v\($0))" } ?? ""
            let menuItem = NSMenuItem(title: "\(chrome.name)\(versionStr)", action: #selector(chromeVariantSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = chrome.variant
            menuItem.state = (chrome.variant == selected?.variant) ? .on : .off
            submenu.addItem(menuItem)
            chromeVariantItems.append(menuItem)
        }

        if chromeVariantItems.isEmpty {
            let none = NSMenuItem(title: "No compatible Chrome found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            chromeVariantItems.append(none)
        }
    }

    // MARK: - Per-profile menu items

    private var profileInsertionIndex: Int = 0
    private var profileMenuItems: [NSMenuItem] = []
    private var activeProfileItem: NSMenuItem?
    private var lastProfileList: [String] = []
    private var lastSelectedProfile: String = ""
    private var darcOverrideItem: NSMenuItem?
    private var darcOverrideSeparator: NSMenuItem?

    private func rebuildProfileItems() {
        guard let menu = statusItem?.menu else { return }

        let state = ExternalState.shared
        let selected = state.selectedProfileName()
        var profiles = state.chromeProfiles.map(\.name)

        // Always show "default" even if the folder doesn't exist yet
        if !profiles.contains("default") {
            profiles.insert("default", at: 0)
        }

        // Skip full rebuild if profile list and selection haven't changed
        if profiles == lastProfileList && selected == lastSelectedProfile && !profileMenuItems.isEmpty {
            return
        }
        lastProfileList = profiles
        lastSelectedProfile = selected

        // Remove old profile items
        for old in profileMenuItems { menu.removeItem(old) }
        profileMenuItems.removeAll()

        // Clear active-profile references
        activeProfileItem = nil
        darcItem = nil; darcStartItem = nil; darcStopItem = nil
        chromeItem = nil; chromeStartItem = nil; chromeStopItem = nil
        chromeHeadlessItem = nil; chromeSubmenu = nil
        darcOverrideItem = nil; darcOverrideSeparator = nil

        var insertIdx = profileInsertionIndex
        for name in profiles {
            let isActive = (name == selected)
            let hasOverride = state.darcOverrideURL(forProfile: name) != nil
            let profileTitle = hasOverride ? "\(name) (dev proxy)" : name
            let profileItem = NSMenuItem(title: profileTitle, action: nil, keyEquivalent: "")
            let profileSubmenu = NSMenu()
            profileSubmenu.autoenablesItems = false

            // "Select" item with checkmark for active profile
            let selectItem = NSMenuItem(title: "Select", action: #selector(profileSelected(_:)), keyEquivalent: "")
            selectItem.target = self
            selectItem.representedObject = name
            selectItem.state = isActive ? .on : .off
            profileSubmenu.addItem(selectItem)
            profileSubmenu.addItem(.separator())

            // Xe Computer submenu
            let darcSub = NSMenuItem(title: "Xe Computer", action: nil, keyEquivalent: "")
            let darcMenu = NSMenu()
            darcMenu.autoenablesItems = false
            let dStart = NSMenuItem(title: "Start", action: #selector(darcStartAction), keyEquivalent: "")
            let dStop = NSMenuItem(title: "Stop", action: #selector(darcStopAction), keyEquivalent: "")
            dStart.target = self; dStop.target = self
            dStart.isEnabled = isActive; dStop.isEnabled = isActive
            darcMenu.addItem(dStart)
            darcMenu.addItem(dStop)

            if isActive {
                // "Override URL..." item — hidden by default, shown when Option is held
                let overrideSep = NSMenuItem.separator()
                overrideSep.isHidden = true
                darcMenu.addItem(overrideSep)

                let currentOverride = state.darcOverrideURL(forProfile: name)
                let overrideTitle = currentOverride != nil ? "Override URL (\(currentOverride!))..." : "Override URL..."
                let overrideItem = NSMenuItem(title: overrideTitle, action: #selector(darcOverrideURLAction), keyEquivalent: "")
                overrideItem.target = self
                overrideItem.isHidden = true
                darcMenu.addItem(overrideItem)

                darcOverrideSeparator = overrideSep
                darcOverrideItem = overrideItem
            }

            darcSub.submenu = darcMenu
            profileSubmenu.addItem(darcSub)

            // Chrome Engine submenu
            let chromeSub = NSMenuItem(title: "Chrome Engine", action: nil, keyEquivalent: "")
            let chromeMenu = NSMenu()
            chromeMenu.autoenablesItems = false
            let cStart = NSMenuItem(title: "Start", action: #selector(chromeStartAction), keyEquivalent: "")
            let cStop = NSMenuItem(title: "Stop", action: #selector(chromeStopAction), keyEquivalent: "")
            let cHeadless = NSMenuItem(title: "Headless", action: #selector(chromeHeadlessAction), keyEquivalent: "")
            cStart.target = self; cStop.target = self; cHeadless.target = self
            cStart.isEnabled = isActive; cStop.isEnabled = isActive; cHeadless.isEnabled = isActive
            chromeMenu.addItem(cStart)
            chromeMenu.addItem(cStop)
            chromeMenu.addItem(cHeadless)
            chromeSub.submenu = chromeMenu
            profileSubmenu.addItem(chromeSub)

            profileItem.submenu = profileSubmenu
            menu.insertItem(profileItem, at: insertIdx)
            profileMenuItems.append(profileItem)
            insertIdx += 1

            // Store references for the active profile so renderMenuLabels can update them
            if isActive {
                activeProfileItem = profileItem
                darcItem = darcSub
                darcStartItem = dStart
                darcStopItem = dStop
                chromeItem = chromeSub
                chromeStartItem = cStart
                chromeStopItem = cStop
                chromeHeadlessItem = cHeadless
                chromeSubmenu = chromeMenu
            }
        }
    }

    @objc private func profileSelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let state = ExternalState.shared
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning

        state.selectProfile(name)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    @objc private func newProfileAction() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Enter a name for the new profile:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "profile-name"
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let state = ExternalState.shared
        if let err = state.createProfile(name: name) {
            let errAlert = NSAlert()
            errAlert.messageText = "Error"
            errAlert.informativeText = err
            errAlert.runModal()
            return
        }

        // Select and start with the new profile
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning
        state.selectProfile(name)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            _ = state.startChrome()
            renderMenuLabels()
        }
    }

    @objc private func chromeVariantSelected(_ sender: NSMenuItem) {
        guard let variant = sender.representedObject as? String else { return }
        let state = ExternalState.shared
        let wasRunning = state.chromeRunning
        let darcWasRunning = state.darcRunning

        state.selectChromeVariant(variant)

        if wasRunning {
            runServiceAction("chrome") {
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    private func setTargets(for menu: NSMenu) {
        for item in menu.items {
            item.target = self
            if let submenu = item.submenu { setTargets(for: submenu) }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        renderMenuLabels()
        guard !isPreparingForTermination else { return }
        let optionHeld = isOptionKeyHeld
        lastOptionKeyState = optionHeld
        updateOptionOnlyMenuItems(optionHeld: optionHeld)
        startStateRefreshLoop()
        // Monitor Option key press/release while menu is open to toggle variant items.
        // NSMenu runs its own event tracking loop so neither addLocalMonitor nor
        // addGlobalMonitor reliably fires during nested submenu tracking.
        // Use a polling timer instead.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let optionHeld = self.isOptionKeyHeld
                if optionHeld != self.lastOptionKeyState {
                    self.lastOptionKeyState = optionHeld
                    if let chromeSubmenu = self.chromeSubmenu {
                        self.refreshChromeMenuOptions(in: chromeSubmenu)
                        chromeSubmenu.update()
                    }
                    self.updateOptionOnlyMenuItems(optionHeld: optionHeld)
                }
            }
        }
        // Add to both common and event tracking run loop modes so it fires during menu tracking
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        optionKeyTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        stopStateRefreshLoop()
        if let specialKeyCheck {
            NSEvent.removeMonitor(specialKeyCheck)
            self.specialKeyCheck = nil
        }
        optionKeyTimer?.invalidate()
        optionKeyTimer = nil
        lastOptionKeyState = false
        chromeVariantsScanned = false
        updateOptionOnlyMenuItems(optionHeld: false)
    }

    private func updateOptionOnlyMenuItems(optionHeld: Bool) {
        darcOverrideItem?.isHidden = !optionHeld
        darcOverrideSeparator?.isHidden = !optionHeld
        newProfileItem?.isHidden = !optionHeld
        saveWindowPositionsItem?.isHidden = !optionHeld
        restoreWindowPositionsItem?.isHidden = !optionHeld
        systemLogsItem?.isHidden = !optionHeld
        openAppDataFolderItem?.isHidden = !optionHeld
        openAppDataFolderSeparator?.isHidden = !optionHeld
        advancedItemsSeparator?.isHidden = !optionHeld
        localAppPortsItem?.isHidden = !optionHeld
        composeStorageFolderItem?.isHidden = !optionHeld
        updateChannelItem?.isHidden = !optionHeld
        statusItem?.menu?.update()
    }

    // MARK: - Render (reads cached state only, no I/O)

    private func serviceTitle(_ name: String, key: String, running: Bool) -> String {
        if pendingServices.contains(key) { return "\(name) ⏳" }
        return running ? "\(name) 🟢" : name
    }

    private func renderMenuLabels() {
        if isPreparingForTermination {
            updateShutdownStatus()
            if let menu = statusItem?.menu {
                disableMenuItemsForShutdown(in: menu)
                menu.update()
            }
            return
        }

        let state = ExternalState.shared
        let configuredPorts = WorkerdPorts(settings: state.settings.rawData)
        if settingsRestartRequired {
            statusMessageItem?.title = "Status: Restart needed for settings"
        } else if workerdServer.usesStandardPorts && !workerdServer.servingStandardPorts {
            statusMessageItem?.title = "Status: Local ports 80/443 not ready"
        } else {
            statusMessageItem?.title = "Status: \(ContainerRuntimePresentation.shared.snapshot.menuDescription)"
        }
        localAppPortsItem?.title = "Local App Ports: \(configuredPorts.http)/\(configuredPorts.https)…"

        // Rebuild per-profile menu items (sets darcItem, chromeItem, etc.)
        rebuildProfileItems()

        // Update active profile title with status indicator
        // 🟢 = both darc + chrome running, 🔵 = chrome only, ⏳ = pending
        if let activeProfileItem {
            let name = state.selectedProfileName()
            let hasOverride = state.darcOverrideURL(forProfile: name) != nil
            let baseName = hasOverride ? "\(name) (dev proxy)" : name
            let anyPending = pendingServices.contains("chrome") || pendingServices.contains("darc")
            if anyPending {
                activeProfileItem.title = "\(baseName) ⏳"
            } else if state.chromeRunning && state.darcRunning {
                activeProfileItem.title = "\(baseName) 🟢"
            } else if state.chromeRunning {
                activeProfileItem.title = "\(baseName) 🔵"
            } else {
                activeProfileItem.title = baseName
            }
        }

        // Update titles and enable states for active profile items
        darcItem?.title = serviceTitle("Xe Computer", key: "darc", running: state.darcRunning)
        let chromeName = state.selectedChrome()?.name ?? "Chrome Engine"
        chromeItem?.title = serviceTitle(chromeName, key: "chrome", running: state.chromeRunning)

        let darcPending = pendingServices.contains("darc")
        let chromePending = pendingServices.contains("chrome")

        darcStartItem?.isEnabled = !state.darcRunning && !darcPending
        darcStopItem?.isEnabled = state.darcRunning && !darcPending
        chromeStartItem?.isEnabled = !state.chromeRunning && !chromePending
        chromeStopItem?.isEnabled = state.chromeRunning && !chromePending
        chromeHeadlessItem?.state = state.boolSetting("chrome_headless", default: true) ? .on : .off

        // Refresh chrome variant options (only adds items when Option key is held)
        if let chromeSubmenu {
            refreshChromeMenuOptions(in: chromeSubmenu)
        }

        runAtStartupItem?.state = state.boolSetting("run_at_startup", default: false) ? .on : .off
        bindCapslockItem?.state = state.boolSetting("bind_capslock", default: false) ? .on : .off
        hideDockIconItem?.state = state.boolSetting("hide_dock_icon", default: false) ? .on : .off
        if isUpdaterConfigured && !ApplicationInstaller.isRunningFromDiskImage() {
            checkForUpdatesItem?.isEnabled = updaterController.updater.canCheckForUpdates
        } else {
            checkForUpdatesItem?.isEnabled = true
        }

        // Force menu to notice title changes
        statusItem?.menu?.update()
    }

    private func runServiceAction(_ key: String, action: @escaping @Sendable () -> Void) {
        pendingServices.insert(key)
        renderMenuLabels()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            action()
            Task { @MainActor [weak self] in
                self?.pendingServices.remove(key)
                self?.renderMenuLabels()
            }
        }
    }

    // MARK: - Actions

    @objc private func darcStartAction() {
        runServiceAction("darc") {
            _ = ExternalState.shared.startDarc()
        }
    }

    @objc private func darcStopAction() {
        runServiceAction("darc") {
            ExternalState.shared.stopDarc()
        }
    }

    @objc private func darcSaveWindowPositionsAction() {
        DispatchQueue.global(qos: .userInitiated).async {
            ExternalState.shared.saveDarcWindowPositions()
        }
    }

    @objc private func darcRestoreWindowPositionsAction() {
        DispatchQueue.global(qos: .userInitiated).async {
            ExternalState.shared.restoreDarcWindowPositions()
        }
    }

    @objc private func openAppDataFolderAction() {
        let url = ExternalState.appDataURL
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "App Data Folder Could Not Be Opened"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func changeLocalAppPortsAction() {
        guard LauncherSetup.changePortChoice() else { return }
        settingsRestartRequired = true
        renderMenuLabels()
        showSettingsRestartAlert()
    }

    @objc private func changeStorageFolderAction() {
        guard LauncherSetup.changeStorageFolder() else { return }
        settingsRestartRequired = true
        renderMenuLabels()
        showSettingsRestartAlert()
    }

    private func showSettingsRestartAlert() {
        let alert = NSAlert()
        alert.messageText = "Restart Xe Launcher to Apply Changes"
        alert.informativeText = "Your new local app ports or Compose storage folder are saved. Running services will keep their current settings until you quit and reopen Xe Launcher."
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    @objc private func darcOverrideURLAction() {
        let state = ExternalState.shared
        let profileName = state.selectedProfileName()
        let currentURL = state.darcOverrideURL(forProfile: profileName) ?? ""

        let alert = NSAlert()
        alert.messageText = "Override Xe Computer URL"
        alert.informativeText = "Enter the base URL for the Xe Computer IWA.\nLeave empty to use the default local bundle.\nThe URL will be validated by checking /.well-known/manifest.webmanifest"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        // Wrap text field in a container with padding to avoid focus ring clipping
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        let input = NSTextField(frame: NSRect(x: 4, y: 4, width: 392, height: 24))
        input.placeholderString = "https://localhost:5194"
        input.stringValue = currentURL.isEmpty ? "https://localhost:5194" : currentURL
        container.addSubview(input)
        alert.accessoryView = container

        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(input)
        let response = alert.runModal()

        // Cancel (third button)
        guard response != .alertThirdButtonReturn else { return }

        // Clear (second button) — remove the override
        if response == .alertSecondButtonReturn {
            state.setDarcOverrideURL(forProfile: profileName, url: nil)
            lastProfileList = [] // Force menu rebuild
            renderMenuLabels()
            return
        }

        let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // If empty, clear the override
        if url.isEmpty {
            state.setDarcOverrideURL(forProfile: profileName, url: nil)
            lastProfileList = [] // Force menu rebuild
            renderMenuLabels()
            return
        }

        // Validate URL format
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            let err = NSAlert()
            err.messageText = "Invalid URL"
            err.informativeText = "URL must start with http:// or https://"
            err.alertStyle = .warning
            err.runModal()
            return
        }

        // Validate by checking manifest endpoint
        let manifestURL = url.hasSuffix("/")
            ? "\(url).well-known/manifest.webmanifest"
            : "\(url)/.well-known/manifest.webmanifest"

        guard let requestURL = URL(string: manifestURL) else {
            let err = NSAlert()
            err.messageText = "Invalid URL"
            err.informativeText = "Could not parse URL: \(manifestURL)"
            err.alertStyle = .warning
            err.runModal()
            return
        }

        // Perform HEAD request asynchronously, ignoring certificate errors for dev servers
        var request = URLRequest(url: requestURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        Task {
            do {
                let session = URLSession(configuration: .ephemeral, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
                let (_, response) = try await session.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                await MainActor.run {
                    guard let status = httpResponse?.statusCode, (200..<300).contains(status) else {
                        let statusCode = httpResponse?.statusCode ?? 0
                        let err = NSAlert()
                        err.messageText = "Validation Failed"
                        err.informativeText = "HEAD \(manifestURL) returned status \(statusCode)"
                        err.alertStyle = .warning
                        err.runModal()
                        return
                    }

                    // Validation passed — save the override
                    state.setDarcOverrideURL(forProfile: profileName, url: url)
                    self.lastProfileList = [] // Force menu rebuild to update title
                    self.renderMenuLabels()
                }
            } catch {
                await MainActor.run {
                    let err = NSAlert()
                    err.messageText = "Validation Failed"
                    err.informativeText = "Could not reach \(manifestURL):\n\(error.localizedDescription)"
                    err.alertStyle = .warning
                    err.runModal()
                }
            }
        }
    }

    @objc private func chromeStartAction() {
        runServiceAction("chrome") {
            _ = ExternalState.shared.startChrome()
        }
    }

    @objc private func chromeStopAction() {
        runServiceAction("chrome") {
            let state = ExternalState.shared
            state.stopDarc()
            state.stopChrome()
        }
    }

    @objc private func chromeHeadlessAction() {
        let current = ExternalState.shared.boolSetting("chrome_headless", default: true)
        let next = !current
        ExternalState.shared.setBoolSetting("chrome_headless", next)

        if ExternalState.shared.chromeRunning {
            runServiceAction("chrome") {
                let darcWasRunning = ExternalState.shared.darcRunning
                if darcWasRunning { ExternalState.shared.stopDarc() }
                ExternalState.shared.stopChrome()
                _ = ExternalState.shared.startChrome()
                if darcWasRunning { _ = ExternalState.shared.startDarc() }
            }
        } else {
            renderMenuLabels()
        }
    }

    @objc private func showLogsAction() {
        logPanelController.present()
    }

    @objc private func runAtStartupAction() {
        let current = ExternalState.shared.boolSetting("run_at_startup", default: false)
        ExternalState.shared.setBoolSetting("run_at_startup", !current)
        renderMenuLabels()
    }

    @objc private func bindCapslockAction() {
        let current = ExternalState.shared.boolSetting("bind_capslock", default: false)
        ExternalState.shared.setBoolSetting("bind_capslock", !current)
        renderMenuLabels()
    }

    @objc private func hideDockIconAction() {
        let state = ExternalState.shared
        let isHidden = state.boolSetting("hide_dock_icon", default: false)
        state.setBoolSetting("hide_dock_icon", !isHidden)
        renderMenuLabels()

        // A Dock-menu action runs inside the Dock's menu tracking loop.
        // Changing activation policy synchronously can leave a stale inactive
        // tile behind, so apply it after the menu action has completed.
        DispatchQueue.main.async { [weak self] in
            self?.applyDockIconPreference()
        }
    }

    private func configureApplicationIdentity() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Xe Launcher"
        ProcessInfo.processInfo.processName = displayName

        if let resourceURL = Bundle.main.resourceURL,
           let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("app.icns")) {
            NSApp.applicationIconImage = icon
        }
    }

    private func applyDockIconPreference() {
        let shouldHide = ExternalState.shared.boolSetting("hide_dock_icon", default: false)
        NSApp.setActivationPolicy(shouldHide ? .accessory : .regular)
    }

    @objc private func aboutAction() {
        let profileName = ExternalState.shared.selectedProfileName()
        let components = ComponentVersions.bundled(
            resourceURL: Bundle.main.resourceURL,
            contentsURL: Bundle.main.bundleURL.appendingPathComponent("Contents"),
            heliumAppURL: ExternalState.resolveHelperApp(name: "Helium.app"),
            darcActivation: activeConfiguredDarcBundleActivation(
                dataURL: ExternalState.appDataURL,
                profileName: profileName
            )
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: releaseVersion,
            .credits: NSAttributedString(
                string: ComponentVersions.aboutText(for: components),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ]

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)

        // The standard About panel is untitled. Promote the key window on the
        // next run-loop turn, after status-menu tracking has finished.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.keyWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func checkForUpdatesAction() {
        guard isUpdaterConfigured else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates Are Not Configured"
            alert.informativeText = "This development build does not contain a Sparkle update-signing public key."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        guard !ApplicationInstaller.isRunningFromDiskImage() else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Install Xe Launcher to Update"
            alert.informativeText = "Updates can be installed after Xe Launcher has been copied to an Applications folder."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard updaterController.updater.canCheckForUpdates else {
            ExternalState.shared.appendLog("launcher", "An update check is already in progress")
            return
        }
        ExternalState.shared.appendLog(
            "launcher",
            "Checking for updates on \(updateChannel.displayName); feed=\(updateChannel.feedURLString)"
        )
        updaterController.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard var components = URLComponents(string: updateChannel.feedURLString) else {
            return updateChannel.feedURLString
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "check", value: updateFeedCacheKey)
        ]
        return components.string
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // raw.githubusercontent.com serves the channel feed with a five-minute
        // CDN lifetime. A unique URL for every Sparkle cycle prevents a newly
        // published appcast from being hidden behind the previous CDN entry.
        updateFeedCacheKey = UUID().uuidString
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        ExternalState.shared.appendLog(
            "launcher",
            "Sparkle update cycle ended on \(updateChannel.displayName): \(describeUpdateError(error))"
        )
    }

    private func describeUpdateError(_ error: Error) -> String {
        var descriptions: [String] = []
        var currentError: NSError? = error as NSError
        var depth = 0

        while let errorToDescribe = currentError, depth < 8 {
            var description = "[\(errorToDescribe.domain):\(errorToDescribe.code)] \(errorToDescribe.localizedDescription)"
            if let failingURL = errorToDescribe.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                description += " (\(failingURL.absoluteString))"
            }
            descriptions.append(description)
            currentError = errorToDescribe.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }

        return descriptions.joined(separator: " <- ")
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Background state refresh

    private func startStateRefreshLoop() {
        guard stateRefreshTimer == nil else { return }
        stateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Re-render service state while the menu is open.
            Task { @MainActor [weak self] in self?.renderMenuLabels() }
        }
    }

    private func stopStateRefreshLoop() {
        stateRefreshTimer?.invalidate()
        stateRefreshTimer = nil
    }
}

// MARK: - Insecure URL session delegate for dev server certificate validation

private final class InsecureURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
