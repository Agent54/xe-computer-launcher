import Foundation
import AppKit
import ApplicationServices

// macOS normally attributes a posix_spawn child’s privacy-sensitive work to
// its parent. Helium is a separately signed application and must own its own
// TCC responsibility, just as it does when launched through Launch Services.
// Chromium and LLDB use this Darwin SPI for the same kind of helper launch.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibilitySpawnAttributesSetDisclaim(
    _ attributes: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ disclaim: Int32
) -> Int32

// Chrome launch configuration and lifecycle management.
// Edit the flags and arguments here to customise how Chrome is started.

extension ExternalState {

    /// File handles for Chrome DevTools Protocol pipe transport.
    /// Write CDP commands to `cdpWriteHandle`, read responses from `cdpReadHandle`.
    /// These are set when Chrome starts with --remote-debugging-pipe and can be
    /// bridged to a Unix socket for workerd or other consumers.
    private static let _cdpHandles = CDPHandles()

    var cdpWriteHandle: FileHandle? {
        get { Self._cdpHandles.writeHandle }
        set { Self._cdpHandles.writeHandle = newValue }
    }
    var cdpReadHandle: FileHandle? {
        get { Self._cdpHandles.readHandle }
        set { Self._cdpHandles.readHandle = newValue }
    }

    /// Command-line flags passed to Chrome on every launch.
    static let chromeFlags: [String] = [
        "--silent-launch",
        "--no-default-browser-check",
        "--no-first-run",
        // TODO: support "--proxy-server=http://127.0.0.1:8080",
        "--flag-switches-begin",
        "--enable-features=AppShimNotificationAttribution,DesktopPWAsAdditionalWindowingControls,DesktopPWAsLinkCapturingWithScopeExtensions,DesktopPWAsSubApps,IsolatedWebAppDevMode,IsolatedWebApps,OverscrollEffectOnNonRootScrollers,UseAdHocSigningForWebAppShims,PwaNavigationCapturing,UnframedIwa,WebAppBorderless,WebAppPredictableAppUpdating",
        "--disable-features=CADisplayLinkInBrowser,AutomationControlled",
        "--disable-blink-features=AutomationControlled",
        "--flag-switches-end"
    ]
    // DO NOT DELETE:
    //   --remote-debugging-port=9226 \
    //   --remote-allow-origins=https://localhost:5194 \

    /// Path to the Unix domain socket used for Chrome DevTools debugging.
    /// Lives under sockets/ in the user app data directory.
    static var debugSocketPath: String {
        appDataURL.appendingPathComponent("sockets/chrome-debug.sock").path
    }

    func startChrome() -> String? {
        // Re-check if the configured chrome is available (it may have been downloaded since last check)
        refreshChromeAvailability()

        let profileName = selectedProfileName()
        let profileDir = Self.appDataURL.appendingPathComponent("profiles/\(profileName)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: profileDir.path) {
            if let err = createProfile(name: profileName) { return err }
        }

        // Ensure sockets directory exists for the debug pipe
        let socketsDir = Self.appDataURL.appendingPathComponent("sockets", isDirectory: true)
        try? FileManager.default.createDirectory(at: socketsDir, withIntermediateDirectories: true)

        guard let chrome = preferredChrome() else { return "No supported Chrome installation found" }

        var args = [
            "--user-data-dir=\(profileDir.path)",
            "--remote-debugging-pipe"
        ] + Self.chromeFlags
        if boolSetting("chrome_headless", default: false) {
            args.append("--headless=new")
            // Override User-Agent globally (including workers) to remove "HeadlessChrome"
            let majorVersion = chrome.version ?? 145
            args.append("--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(majorVersion).0.0.0 Safari/537.36")
        }

        // Install the IWA: use override URL if set for this profile, otherwise use local file.
        // --install-isolated-web-app-from-url is only needed for the initial install (shim not yet present).
        let isDevProxy = darcOverrideURL(forProfile: profileName) != nil
        let shimDir = Self.appDataURL.appendingPathComponent("shims/\(profileName)", isDirectory: true)
        let devShimExists = FileManager.default.fileExists(atPath: shimDir.appendingPathComponent("Darc Dev.app").path)

        if let overrideURL = darcOverrideURL(forProfile: profileName),
           (overrideURL.hasPrefix("http://") || overrideURL.hasPrefix("https://")),
           !devShimExists {
            args.append("--install-isolated-web-app-from-url=\(overrideURL)")
        } else if !isDevProxy {
            let iwaPath = Self.appDataURL.appendingPathComponent("darc.swbn").path
            if FileManager.default.fileExists(atPath: iwaPath) {
                args.append("--install-isolated-web-app-from-file=\(iwaPath)")
            }
        }

        // Create pipe pairs for Chrome DevTools Protocol pipe transport.
        // Chrome reads commands from fd 3 and writes responses to fd 4.
        // We keep the other ends for our launcher / future workerd bridge.
        let toChrome = Pipe()    // we write → Chrome reads on fd 3
        let fromChrome = Pipe()  // Chrome writes on fd 4 → we read

        do {
            // spawnLongRunningProcessWithPipes closes the child-side handles after spawn
            let _ = try spawnLongRunningProcessWithPipes(
                executable: chrome.executablePath,
                arguments: args,
                source: "browser",
                extraFDs: [
                    3: toChrome.fileHandleForReading,
                    4: fromChrome.fileHandleForWriting
                ]
            )

            // Store the pipe handles for later CDP communication (e.g. workerd bridge)
            cdpWriteHandle = toChrome.fileHandleForWriting
            cdpReadHandle = fromChrome.fileHandleForReading

            appendLog("launcher", "Chrome started with debug pipe (\(chrome.name), pid=\(_browserPid), isRunning=\(chromeRunning))")
            print("[ExternalState] Chrome started, isRunning=\(chromeRunning)")

            // Apply anti-detection patches when running in headless mode
            if boolSetting("chrome_headless", default: false) {
                preventDetection()
            }

            // Check if app shim needs provisioning (in parallel)
            let shimAppName = isDevProxy ? "Darc Dev.app" : "Darc.app"
            let shimApp = shimDir.appendingPathComponent(shimAppName)
            if !FileManager.default.fileExists(atPath: shimApp.path) {
                provisionAppShim(profileName: profileName, profileDir: profileDir, shimApp: shimApp, chrome: chrome)
            }

            return nil
        } catch {
            let msg = "Chrome start failed: \(error)"
            appendLog("launcher", msg)
            print("[ExternalState] \(msg)")
            return error.localizedDescription
        }
    }

    // MARK: - CDP Pipe Communication

    /// Monotonically increasing CDP message ID.
    nonisolated(unsafe) private static var _cdpNextId: Int = 0
    private static let _cdpIdLock = NSLock()
    private static func nextCDPId() -> Int {
        _cdpIdLock.lock()
        defer { _cdpIdLock.unlock() }
        _cdpNextId += 1
        return _cdpNextId
    }

    /// Leftover data from previous CDP reads (events that arrived between commands).
    nonisolated(unsafe) private static var _cdpReadBuffer = Data()

    /// Send a CDP command over the debugging pipe with a timeout.
    /// The pipe protocol uses \0 as message delimiter.
    /// If `sessionId` is provided, the command is routed to that target session.
    @discardableResult
    func sendCDP(method: String, params: [String: Any] = [:], sessionId: String? = nil, timeout: TimeInterval = 5.0) -> [String: Any]? {
        guard let writeHandle = cdpWriteHandle, let readHandle = cdpReadHandle else {
            appendLog("launcher", "CDP: pipe not available")
            return nil
        }
        let id = Self.nextCDPId()
        var msg: [String: Any] = ["id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        if let sid = sessionId { msg["sessionId"] = sid }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: msg),
              var payload = String(data: jsonData, encoding: .utf8) else {
            appendLog("launcher", "CDP: failed to serialize \(method)")
            return nil
        }
        payload.append("\0")
        writeHandle.write(payload.data(using: .utf8)!)

        let deadline = Date().addingTimeInterval(timeout)
        let fd = readHandle.fileDescriptor

        while Date() < deadline {
            while let zeroIdx = Self._cdpReadBuffer.firstIndex(of: 0) {
                let messageData = Self._cdpReadBuffer[Self._cdpReadBuffer.startIndex..<zeroIdx]
                Self._cdpReadBuffer = Data(Self._cdpReadBuffer[Self._cdpReadBuffer.index(after: zeroIdx)...])

                guard let response = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                    continue
                }
                if let responseId = response["id"] as? Int, responseId == id {
                    return response
                }
            }

            let remainingMs = Int32(max(deadline.timeIntervalSinceNow * 1000, 1))
            var pollFd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pollFd, 1, min(remainingMs, 500))
            if pollResult > 0 {
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { return nil }
                Self._cdpReadBuffer.append(contentsOf: buf[0..<n])
            } else if pollResult < 0 {
                return nil
            }
        }

        appendLog("launcher", "CDP: timeout waiting for response to \(method) (id=\(id))")
        return nil
    }

    func stopChrome() {
        let wasRunning = chromeRunning
        terminateSubprocess("browser")
        appendLog("launcher", "Chrome stopped (wasRunning=\(wasRunning))")
        print("[ExternalState] Chrome stopped (wasRunning=\(wasRunning))")
    }

    /// Provision the app shim in the background.
    /// Chrome creates the shim at ~/Applications/Chromium Apps.localized/Darc.app
    /// on first IWA install. We wait for it, move it to our shims dir, restart Chrome
    /// with a fresh Preferences.json.
    private func provisionAppShim(profileName: String, profileDir: URL, shimApp: URL, chrome: InstalledChrome) {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let appsFolder = chrome.variant == "canary" ? "Chrome Canary Apps.localized" : "Chromium Apps.localized"
            let systemShimPath = NSHomeDirectory() + "/Applications/\(appsFolder)/Darc.app"
            let shimCodeSignature = systemShimPath + "/Contents/_CodeSignature"

            self.appendLog("launcher", "Waiting for app shim at \(systemShimPath)...")

            // Poll for the shim to appear with a valid code signature (max ~20s)
            var found = false
            for _ in 0..<40 {
                if fm.fileExists(atPath: shimCodeSignature) {
                    found = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
                // If Chrome died, abort
                if !self.chromeRunning { break }
            }

            guard found else {
                self.appendLog("launcher", "App shim was not created within timeout")
                return
            }

            self.appendLog("launcher", "App shim found, moving to \(shimApp.path)")

            // Create shims directory
            try? fm.createDirectory(at: shimApp.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Verify the shim's CrAppModeUserDataDir matches our profile dir before moving
            let systemShimPlist = URL(fileURLWithPath: systemShimPath).appendingPathComponent("Contents/Info.plist")
            if let plistData = try? Data(contentsOf: systemShimPlist),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
               let shimUserDataDir = plist["CrAppModeUserDataDir"] as? String {
                if !shimUserDataDir.hasPrefix(profileDir.path) {
                    self.appendLog("launcher", "App shim CrAppModeUserDataDir mismatch: \(shimUserDataDir) does not start with \(profileDir.path), skipping")
                    return
                }
            }

            // Move shim to our managed location
            do {
                try fm.moveItem(atPath: systemShimPath, toPath: shimApp.path)
            } catch {
                self.appendLog("launcher", "Failed to move app shim: \(error.localizedDescription)")
                return
            }

            // Close any Finder windows showing the Helium/Chromium Apps folder
            // Uses AXUIElement Accessibility API directly (requires Accessibility permission only)
            Thread.sleep(forTimeInterval: 2.0)
            self.closeFinderWindowsContaining(["Helium Apps", "Chromium Apps", "Chrome Canary Apps"])

            // Stop Chrome
            self.appendLog("launcher", "Stopping Chrome for Preferences.json refresh...")
            self.stopChrome()

            // Wait a moment for Chrome to fully exit
            Thread.sleep(forTimeInterval: 1.0)

            // Copy Preferences.json over the profile's Default/Preferences
            let defaultDir = profileDir.appendingPathComponent("Default", isDirectory: true)
            try? fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
            let destPrefs = defaultDir.appendingPathComponent("Preferences")
            if let bundlePrefs = Bundle.main.resourceURL?.appendingPathComponent("Preferences.json"),
               fm.fileExists(atPath: bundlePrefs.path) {
                try? fm.removeItem(at: destPrefs)
                do {
                    try fm.copyItem(at: bundlePrefs, to: destPrefs)
                    self.appendLog("launcher", "Copied Preferences.json to \(destPrefs.path)")
                } catch {
                    self.appendLog("launcher", "Failed to copy Preferences.json: \(error.localizedDescription)")
                }
            }

            // Copy Local State over the profile's Local State
            if let bundleLocalState = Bundle.main.resourceURL?.appendingPathComponent("Local State"),
               fm.fileExists(atPath: bundleLocalState.path) {
                let destLocalState = profileDir.appendingPathComponent("Local State")
                try? fm.removeItem(at: destLocalState)
                do {
                    try fm.copyItem(at: bundleLocalState, to: destLocalState)
                    self.appendLog("launcher", "Copied Local State to \(destLocalState.path)")
                } catch {
                    self.appendLog("launcher", "Failed to copy Local State: \(error.localizedDescription)")
                }
            }

            // Restart Chrome
            self.appendLog("launcher", "Restarting Chrome and Darc after shim provisioning...")
            let err = self.startDarc()
            if let err {
                self.appendLog("launcher", "Darc relaunch failed: \(err)")
            }
        }
    }

    /// Close Finder windows whose title contains any of the given substrings.
    /// Uses the macOS Accessibility API (AXUIElement) directly — requires only Accessibility permission,
    /// not the separate "control Finder" Automation permission that AppleScript triggers.
    private func closeFinderWindowsContaining(_ substrings: [String]) {
        guard AXIsProcessTrusted() else {
            appendLog("launcher", "Accessibility permission not granted, cannot close Finder windows")
            return
        }

        // Find the Finder process
        guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            appendLog("launcher", "Finder not running, skipping window close")
            return
        }

        let finderElement = AXUIElementCreateApplication(finderApp.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(finderElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            appendLog("launcher", "Failed to get Finder windows (AX error: \(result.rawValue))")
            return
        }

        appendLog("launcher", "Found \(windows.count) Finder windows")
        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else { continue }

            appendLog("launcher", "Finder window: '\(title)'")
            if substrings.contains(where: { title.contains($0) }) {
                var closeButtonRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
                   let closeButton = closeButtonRef as! AXUIElement? {
                    let pressResult = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                    appendLog("launcher", "Closed Finder window '\(title)' (result: \(pressResult.rawValue))")
                } else {
                    appendLog("launcher", "No close button for Finder window '\(title)'")
                }
            }
        }
    }

    /// Spawn a process with extra file descriptors mapped into the child using posix_spawn.
    /// Uses posix_spawn_file_actions_adddup2 for reliable fd mapping.
    /// Swift's Process uses POSIX_SPAWN_CLOEXEC_DEFAULT which closes all unmapped fds,
    /// so we must use posix_spawn directly to pass fds 3/4 to the child.
    func spawnLongRunningProcessWithPipes(executable: String, arguments: [String], source: String, extraFDs: [Int32: FileHandle]) throws -> Process {
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        env.removeValue(forKey: "__CFBundleIdentifier")

        // Build argv: [executable, args..., NULL]
        let allArgs = [executable] + arguments
        let cArgs = allArgs.map { strdup($0) } + [nil]
        defer { for p in cArgs { if let p { free(p) } } }

        // Build envp: ["KEY=VALUE", ..., NULL]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in cEnv { if let p { free(p) } } }

        // Set up stdout/stderr pipe for log capture
        let outputPipe = Pipe()

        // Configure posix_spawn file actions
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // Map stdout and stderr to our output pipe
        let outWriteFD = outputPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outWriteFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, outWriteFD, STDERR_FILENO)

        // Map extra fds (e.g. 3 for CDP read, 4 for CDP write)
        for (targetFD, handle) in extraFDs {
            posix_spawn_file_actions_adddup2(&fileActions, handle.fileDescriptor, targetFD)
        }

        // Configure spawn attributes — do NOT set POSIX_SPAWN_CLOEXEC_DEFAULT
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        let responsibilityResult = responsibilitySpawnAttributesSetDisclaim(&attrs, 1)
        guard responsibilityResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(responsibilityResult), userInfo: [
                NSLocalizedDescriptionKey: "Could not assign browser privacy responsibility: \(String(cString: strerror(responsibilityResult)))"
            ])
        }

        var pid: pid_t = 0
        let spawnResult = cArgs.withUnsafeBufferPointer { argsBuf in
            cEnv.withUnsafeBufferPointer { envBuf in
                posix_spawnp(
                    &pid,
                    executable,
                    &fileActions,
                    &attrs,
                    UnsafeMutablePointer(mutating: argsBuf.baseAddress!),
                    UnsafeMutablePointer(mutating: envBuf.baseAddress!)
                )
            }
        }

        guard spawnResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult), userInfo: [
                NSLocalizedDescriptionKey: "posix_spawnp failed: \(String(cString: strerror(spawnResult)))"
            ])
        }

        // Close parent-side ends of fds that belong to the child
        outputPipe.fileHandleForWriting.closeFile()
        for (_, handle) in extraFDs {
            handle.closeFile()
        }

        // Set up log capture from the output pipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self?.appendLog(source, t) }
            }
        }

        // Create a Process object to track the pid for subprocess management.
        // We use a lightweight wrapper: monitor the pid with waitpid in background.
        let process = Process()
        // Store the pid for terminateSubprocess to use
        appendLog("launcher", "\(source) spawned via posix_spawn (pid=\(pid))")

        // Monitor child exit in background
        let capturedPid = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(capturedPid, &status, 0)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = (status & 0x7f) == 0 ? Int32((status >> 8) & 0xff) : Int32(-1)
            self?.appendLog(source, "Process exited with code \(exitCode)")
            self?.appendLog("launcher", "\(source) process exited (code=\(exitCode))")
            print("[ExternalState] \(source) process exited (code=\(exitCode))")
        }

        // We can't return a real Process object since we used posix_spawn directly.
        // Store the pid directly for kill management.
        _browserPid = pid
        return process  // Placeholder — terminateSubprocess should use _browserPid
    }
}

// MARK: - Zombie Process Detection

extension ExternalState {

    /// A stale browser-related process found on the system.
    struct ZombieProcess {
        let pid: pid_t
        let name: String       // e.g. "Helium", "app_mode_loader"
        let profileDir: String? // extracted from --user-data-dir if present
    }

    /// Find running Helium / Darc (app_mode_loader) processes that were NOT
    /// spawned by this launcher instance.  These are "zombies" left over from
    /// a previous crash or unclean shutdown.
    func findZombieProcesses() -> [ZombieProcess] {
        // Get all running args via `ps`
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-eo", "pid,comm"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            appendLog("launcher", "findZombieProcesses: failed to decode ps output")
            return []
        }

        // Our own managed PIDs
        let ownBrowserPid = _browserPid
        let ownDarcPid = darcAppRef?.processIdentifier ?? -1
        let ownPid = ProcessInfo.processInfo.processIdentifier
        appendLog("launcher", "findZombieProcesses: ownBrowserPid=\(ownBrowserPid), ownDarcPid=\(ownDarcPid), ownPid=\(ownPid)")

        var zombies: [ZombieProcess] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[trimmed.startIndex..<spaceIdx]) else { continue }
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)

            // Log any processes that look related to Chrome/Helium/Darc
            if comm.contains("Helium") || comm.contains("app_mode_loader") || comm.contains("Darc") {
                appendLog("launcher", "findZombieProcesses: candidate pid=\(pid) comm='\(comm)'")
            }

            let isHelium = comm.hasSuffix("/Helium") || comm == "Helium"
            let isDarc = comm.hasSuffix("/app_mode_loader") || comm == "app_mode_loader"

            guard isHelium || isDarc else { continue }
            guard pid != ownBrowserPid && pid != ownDarcPid else { continue }
            // Don't include our own launcher process
            guard pid != ownPid else { continue }

            // Try to get command-line args to extract --user-data-dir
            let profileDir = Self.extractUserDataDir(pid: pid)
            let name = isHelium ? "Helium" : "Darc (app_mode_loader)"
            zombies.append(ZombieProcess(pid: pid, name: name, profileDir: profileDir))
        }

        return zombies
    }

    /// Extract the --user-data-dir value from a process's command-line arguments using sysctl.
    private static func extractUserDataDir(pid: pid_t) -> String? {
        // Use ps to get full command line
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "args="]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let args = String(data: data, encoding: .utf8) else { return nil }

        // Find --user-data-dir=...
        for part in args.components(separatedBy: " ") {
            if part.hasPrefix("--user-data-dir=") {
                return String(part.dropFirst("--user-data-dir=".count))
            }
        }
        return nil
    }

    /// Kill the given zombie processes.
    func killZombieProcesses(_ zombies: [ZombieProcess]) {
        for z in zombies {
            kill(z.pid, SIGTERM)
            appendLog("launcher", "Killed zombie \(z.name) (pid=\(z.pid))")
        }
        // Give them a moment, then SIGKILL any survivors
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for z in zombies {
                if kill(z.pid, 0) == 0 {
                    kill(z.pid, SIGKILL)
                }
            }
        }
    }
}

/// Thread-safe storage for CDP pipe handles.
private class CDPHandles: @unchecked Sendable {
    var writeHandle: FileHandle?
    var readHandle: FileHandle?
}
