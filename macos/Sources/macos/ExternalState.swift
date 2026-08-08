import Foundation
import AppKit

final class ExternalState: @unchecked Sendable {
    static let appSupportIdentifier = "dev.xe.computer"

    static var appDataURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(appSupportIdentifier, isDirectory: true)
    }

    static var appDataFolder: String { appDataURL.path }
    static var profilesPath: String { appDataURL.appendingPathComponent("profiles", isDirectory: true).path }
    static var vmsPath: String { appDataURL.appendingPathComponent("vms", isDirectory: true).path }
    static var settingsPath: String { appDataURL.appendingPathComponent("settings.json").path }

    static let xeComputerShimAppName = "Xe Computer.app"
    static let xeComputerDevelopmentShimAppName = "Xe Computer Dev.app"

    static func xeComputerShimAppName(isDevelopment: Bool) -> String {
        isDevelopment ? xeComputerDevelopmentShimAppName : xeComputerShimAppName
    }

    private static let logBufferSize = 1000
    private static let colimaProfilePrefix = "darc-"
    private static let requiredChromeFlags = [
        "enable-desktop-pwas-additional-windowing-controls@1",
        "enable-desktop-pwas-borderless@1",
        "enable-experimental-web-platform-features",
        "enable-isolated-web-app-dev-mode@1",
        "enable-isolated-web-apps@1",
        "enable-mac-pwas-notification-attribution@1"
    ]

    struct InstalledChrome {
        let name: String
        let appPath: String
        let executablePath: String
        let variant: String
        let isInstalled: Bool
        let version: Int?
    }

    struct ChromeProfile {
        let name: String
        let path: String
    }

    struct VMProfile {
        let name: String
        let path: String
    }

    struct ColimaInstance: Codable {
        let name: String
        let status: String
        let arch: String?
        let cpus: Int?
        let memory: Int?
        let disk: Int?
        let runtime: String?
        let address: String?
    }

    struct ColimaStatus {
        let isInstalled: Bool
        let isReachable: Bool
        let instances: [ColimaInstance]
        let error: String?
    }

    struct LogEntry {
        let source: String
        let line: String
        let timestamp: Date
    }

    struct DependencyStatus {
        let colima: Bool
        let chrome: InstalledChrome?
        let profiles: [String]
    }

    struct Settings: Codable {
        let rawData: [String: Any]?

        init(rawData: [String: Any]? = nil) {
            self.rawData = rawData
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let data = try? container.decode([String: AnyCodable].self) {
                rawData = data.mapValues { $0.value }
            } else {
                rawData = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let rawData {
                try container.encode(rawData.mapValues { AnyCodable($0) })
            }
        }
    }

    private(set) var installedChromes: [InstalledChrome] = []
    private(set) var chromeProfiles: [ChromeProfile] = []
    private(set) var vmProfiles: [VMProfile] = []
    private(set) var colimaStatus = ColimaStatus(isInstalled: false, isReachable: false, instances: [], error: nil)
    private(set) var settings = Settings(rawData: [:])

    private(set) var legacyVMRunning = false
    private(set) var systemVMRunning = false
    private(set) var appVMRunning = false

    /// Managed long-running subprocesses keyed by name
    var subprocesses: [String: Process] = [:]
    /// PID for the browser process spawned via posix_spawn (not tracked by Process)
    var _browserPid: pid_t = 0
    private var darcApp: NSRunningApplication?
    /// Public read-only access to the Darc NSRunningApplication reference for activation.
    var darcAppRef: NSRunningApplication? {
        darcRunning ? darcApp : nil
    }

    /// Check if a named subprocess is currently running
    func isSubprocessRunning(_ name: String) -> Bool {
        guard let process = subprocesses[name] else { return false }
        return process.isRunning
    }

    var darcRunning: Bool {
        if let app = darcApp, !app.isTerminated { return true }
        darcApp = nil

        // The app shim is intentionally launched through Launch Services, so it
        // is not necessarily a child of this process. In particular, Chrome can
        // launch it while initially provisioning the IWA, before startDarc() has
        // received an NSRunningApplication reference. Rediscover that independent
        // application from the managed shim's path or bundle identifier.
        guard let app = findRunningDarcApplication() else { return false }
        darcApp = app
        return true
    }

    private func darcShimAppURL() -> URL {
        let profileName = selectedProfileName()
        let isDevProxy = darcOverrideURL(forProfile: profileName) != nil
        let shimAppName = Self.xeComputerShimAppName(isDevelopment: isDevProxy)
        return Self.appDataURL.appendingPathComponent("shims/\(profileName)/\(shimAppName)")
    }

    private func findRunningDarcApplication() -> NSRunningApplication? {
        let appURL = darcShimAppURL()
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/app_mode_loader")
        let expectedAppPath = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedExecutablePath = executableURL.standardizedFileURL.resolvingSymlinksInPath().path

        func isExactManagedShim(_ app: NSRunningApplication) -> Bool {
            guard !app.isTerminated else { return false }
            if let bundlePath = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path,
               bundlePath == expectedAppPath {
                return true
            }
            if let executablePath = app.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path,
               executablePath == expectedExecutablePath {
                return true
            }
            return false
        }

        let runningApplications = NSWorkspace.shared.runningApplications
        if let exactMatch = runningApplications.first(where: isExactManagedShim) {
            return exactMatch
        }

        // Launch Services can retain the shim's pre-move bundle URL for an app
        // that Chrome launched before provisioning moved it into our app-data
        // directory. Its generated bundle identifier remains stable, though.
        guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            return nil
        }
        let identifierMatches = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }

        if let exactMatch = identifierMatches.first(where: isExactManagedShim) {
            return exactMatch
        }
        return identifierMatches.count == 1 ? identifierMatches[0] : nil
    }
    var chromeRunning: Bool {
        // Check posix_spawn'd browser pid
        if _browserPid > 0 {
            // kill(pid, 0) checks if process exists without sending a signal
            if kill(_browserPid, 0) == 0 { return true }
            _browserPid = 0
        }
        return isSubprocessRunning("browser")
    }

    private var lastColimaRefresh = Date.distantPast
    private let minColimaRefreshInterval: TimeInterval = 15

    private var allLogs: [LogEntry] = []

    static let shared = ExternalState()
    private init() {}

    func updateAll() {
        ensureAppDataFolderExists()
        refreshChromeAvailability()
        updateChromeProfiles()
        updateVMProfiles()
        refreshRuntimeStateFromSystemTruth(force: true)
        updateSettings()

    }

    func refreshRuntimeStateFromSystemTruth(force: Bool = false) {
        updateColimaStatus(force: force)
    }

    private func ensureAppDataFolderExists() {
        let fm = FileManager.default
        for folder in [Self.appDataFolder, Self.profilesPath, Self.vmsPath] where !fm.fileExists(atPath: folder) {
            do { try fm.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { print("[ExternalState] mkdir failed: \(error)") }
        }
        seedBundledAssets()
    }

    /// Seed VM profile templates and download required assets (Helium, Xe Computer) on first run.
    private func seedBundledAssets() {
        let fm = FileManager.default
        let dataURL = Self.appDataURL

        // --- VM profile templates (from bundle Resources/vms/) ---
        let bundleVMs: URL? = Bundle.main.resourceURL?.appendingPathComponent("vms", isDirectory: true)
        if let bundleVMs, fm.fileExists(atPath: bundleVMs.path) {
            let dstVMs = dataURL.appendingPathComponent("vms", isDirectory: true)
            if let files = try? fm.contentsOfDirectory(atPath: bundleVMs.path) {
                for file in files where file.hasSuffix(".yaml") {
                    let src = bundleVMs.appendingPathComponent(file)
                    let dst = dstVMs.appendingPathComponent(file)
                    if !fm.fileExists(atPath: dst.path) {
                        do {
                            try fm.copyItem(at: src, to: dst)
                            print("[ExternalState] Seeded VM template \(file)")
                        } catch {
                            print("[ExternalState] Failed to seed VM template \(file): \(error)")
                        }
                    }
                }
            }
        }

        // --- Download assets from sources.json on first run ---
        downloadAssetsIfNeeded()
    }

    /// Download assets defined in sources.json if not already present.
    private func downloadAssetsIfNeeded() {
        downloadSourceAssetsIfNeeded(dataURL: Self.appDataURL) { [weak self] source, message in
            self?.appendLog(source, message)
        }
    }

    /// Resolve a helper app path: prefer the user data dir copy (avoids signature issues),
    /// fall back to the app bundle's Helpers/.
    static func resolveHelperApp(name: String) -> URL {
        let userCopy = appDataURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: userCopy.path) {
            return userCopy
        }
        if let bundleHelpers = Bundle.main.resourceURL?.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true) {
            let bundlePath = bundleHelpers.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                return bundlePath
            }
        }
        return userCopy
    }

    /// Update the list of known Chrome installations.
    /// - Parameter scanAll: When `true` (e.g. Option key held), scan for all known Chrome variants.
    ///   When `false` (default), only populate the configured variant (defaults to Helium) to avoid
    ///   silently falling back to a different browser.
    func refreshChromeAvailability(scanAll: Bool = false) {
        let heliumApp = Self.resolveHelperApp(name: "Helium.app")
        let heliumExec = heliumApp.appendingPathComponent("Contents/MacOS/Helium")
        let allChromePaths: [(String, String, String, String)] = [
            ("Helium", heliumApp.path, heliumExec.path, "helium"),
            ("Google Chrome Beta", "/Applications/Google Chrome Beta.app", "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta", "beta"),
            ("Google Chrome", "/Applications/Google Chrome.app", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "stable"),
            ("Google Chrome Canary", "/Applications/Google Chrome Canary.app", "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary", "canary")
        ]

        let fm = FileManager.default
        let chromePaths: [(String, String, String, String)]
        if scanAll {
            chromePaths = allChromePaths
        } else {
            // Only check the currently configured variant (default: helium)
            let savedVariant = settings.rawData?["selected_chrome_variant"] as? String ?? "helium"
            chromePaths = allChromePaths.filter { $0.3 == savedVariant }
        }

        installedChromes = chromePaths.map { name, app, exec, variant in
            InstalledChrome(
                name: name,
                appPath: app,
                executablePath: exec,
                variant: variant,
                isInstalled: fm.fileExists(atPath: app),
                version: readChromeMajorVersion(appPath: app)
            )
        }
    }

    func updateChromeProfiles() {
        let path = Self.profilesPath
        chromeProfiles = getSubfolders(at: path).map { ChromeProfile(name: $0, path: "\(path)/\($0)") }
    }

    func updateVMProfiles() {
        let path = Self.vmsPath
        vmProfiles = getYamlFiles(at: path).map {
            let name = ($0 as NSString).deletingPathExtension
            return VMProfile(name: name, path: "\(path)/\($0)")
        }
    }

    func updateColimaStatus(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastColimaRefresh) < minColimaRefreshInterval {
            return
        }
        lastColimaRefresh = now

        guard let colimaPath = resolveExecutable(name: "colima") else {
            colimaStatus = ColimaStatus(isInstalled: false, isReachable: false, instances: [], error: "Colima not found")
            legacyVMRunning = false; systemVMRunning = false; appVMRunning = false
            return
        }

        let listResult = runCommand(colimaPath, arguments: ["list", "--json"])
        guard listResult.exitCode == 0 else {
            colimaStatus = ColimaStatus(isInstalled: true, isReachable: false, instances: [], error: listResult.error)
            legacyVMRunning = false; systemVMRunning = false; appVMRunning = false
            return
        }

        var instances: [ColimaInstance] = []
        for line in listResult.output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, let data = t.data(using: .utf8) else { continue }
            if let instance = try? JSONDecoder().decode(ColimaInstance.self, from: data) {
                instances.append(instance)
            }
        }

        colimaStatus = ColimaStatus(isInstalled: true, isReachable: true, instances: instances, error: nil)
        legacyVMRunning = isColimaProfileRunning("darc")
        systemVMRunning = isColimaProfileRunning("\(Self.colimaProfilePrefix)system")
        appVMRunning = isColimaProfileRunning("\(Self.colimaProfilePrefix)apps")
    }

    func updateSettings() {
        let path = Self.settingsPath
        guard FileManager.default.fileExists(atPath: path) else { settings = Settings(rawData: [:]); return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let json = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
            settings = Settings(rawData: json ?? [:])
        } catch {
            settings = Settings(rawData: [:])
        }
    }

    func boolSetting(_ key: String, default defaultValue: Bool = false) -> Bool {
        (settings.rawData?[key] as? Bool) ?? defaultValue
    }

    func setBoolSetting(_ key: String, _ value: Bool) {
        let current = (settings.rawData?[key] as? Bool)
        if current == value { return }

        var dict = settings.rawData ?? [:]
        dict[key] = value
        settings = Settings(rawData: dict)
        saveSettings()
    }

    func saveSettings() {
        let path = Self.settingsPath
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: settings.rawData ?? [:], options: [.prettyPrinted])
            try json.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("[ExternalState] save settings failed: \(error)")
        }
    }

    func checkDependencies() -> DependencyStatus {
        refreshChromeAvailability()
        updateChromeProfiles()
        return DependencyStatus(
            colima: resolveExecutable(name: "colima") != nil,
            chrome: preferredChrome(),
            profiles: chromeProfiles.map(\.name)
        )
    }

    var isColimaInstalled: Bool {
        resolveExecutable(name: "colima") != nil
    }

    var isHomebrewInstalled: Bool {
        resolveExecutable(name: "brew") != nil
    }

    func installColima() -> String? {
        guard !isColimaInstalled else { return nil }
        guard let brewPath = resolveExecutable(name: "brew") else {
            return "Colima is not installed and Homebrew could not be found. Install Homebrew and restart Xe Launcher, or install Colima manually."
        }

        appendLog("launcher", "Colima not found; installing it with Homebrew")
        let result = runCommand(brewPath, arguments: ["install", "colima"])
        result.output.split(separator: "\n").forEach { appendLog("homebrew", String($0)) }
        result.error.split(separator: "\n").forEach { appendLog("homebrew", String($0)) }

        guard result.exitCode == 0 else {
            let detail = (result.error.isEmpty ? result.output : result.error)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : "\n\nHomebrew reported:\n\(String(detail.suffix(1200)))"
            return "Homebrew could not install Colima. Run `brew install colima` in Terminal or install Colima manually.\(suffix)"
        }

        guard isColimaInstalled else {
            return "Homebrew finished without an error, but Colima could not be found. Run `brew install colima` in Terminal or install Colima manually."
        }

        appendLog("launcher", "Colima installed successfully with Homebrew")
        return nil
    }

    func launchBrowserStack() -> String? {
        if boolSetting("chrome_was_running", default: true), let err = startChrome() { return err }
        if boolSetting("darc_was_running", default: true), let err = startDarc() { return err }
        return nil
    }

    func getLogs(source: String? = nil) -> [LogEntry] {
        if let source {
            return allLogs.filter { $0.source == source }
        }
        return allLogs
    }

    func clearLogs(source: String? = nil) {
        if let source {
            allLogs.removeAll { $0.source == source }
        } else {
            allLogs.removeAll()
        }
    }

    func appendLog(_ source: String, _ line: String) {
        if allLogs.count >= Self.logBufferSize {
            allLogs.removeFirst(allLogs.count - Self.logBufferSize + 1)
        }
        allLogs.append(LogEntry(source: source, line: line, timestamp: Date()))
    }


    func startDarc() -> String? {
        if !chromeRunning, let err = startChrome() { return err }

        let appURL = darcShimAppURL()
        let loader = appURL.appendingPathComponent("Contents/MacOS/app_mode_loader").path
        guard FileManager.default.isExecutableFile(atPath: loader) else {
            let msg = "Xe Computer loader not found at \(loader)"
            appendLog("launcher", msg)
            print("[ExternalState] \(msg)")
            return msg
        }

        // Launch via NSWorkspace so the app shim runs as an independent
        // application (not as a child process of the launcher). This matches
        // the behaviour of launching from Finder / terminal `open`.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let semaphore = DispatchSemaphore(value: 0)
        class Box: @unchecked Sendable { var error: String? }
        let box = Box()
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [weak self] app, error in
            if let error {
                box.error = "Xe Computer open failed: \(error.localizedDescription)"
            } else if let app {
                self?.darcApp = app
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        if let err = box.error {
            appendLog("launcher", err)
            print("[ExternalState] \(err)")
            return err
        }
        let running = darcRunning
        let pid = darcApp?.processIdentifier ?? -1
        appendLog("launcher", "Xe Computer started via NSWorkspace (isRunning=\(running), pid=\(pid))")
        print("[ExternalState] Xe Computer started, isRunning=\(running)")

        // Bring the Darc app to the foreground (silently — ignore if app terminated)
        if let app = darcApp, !app.isTerminated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if let ref = self?.darcApp, !ref.isTerminated {
                    ref.activate()
                }
            }
        }

        // Start a background `log stream` to capture NSLog output from app_mode_loader
        if pid > 0 {
            startAppShimLogStream(pid: pid)
        }
        return nil
    }

    func stopDarc() {
        let wasRunning = darcRunning
        if let app = darcApp, !app.isTerminated {
            app.terminate()
        }
        darcApp = nil
        terminateSubprocess("darc_log")
        appendLog("launcher", "Xe Computer stopped (wasRunning=\(wasRunning))")
        print("[ExternalState] Xe Computer stopped (wasRunning=\(wasRunning))")
    }

    private func desktopForWindow(_ windowID: UInt32) -> Int? {
        // Use CGSCopySpacesForWindows to get the space ID for a window
        typealias CGSDefaultConnectionFunc = @convention(c) () -> UInt32
        typealias CGSCopySpacesForWindowsFunc = @convention(c) (UInt32, UInt32, CFArray) -> CFArray?

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            print("[ExternalState] dlopen CoreGraphics failed")
            return nil
        }
        defer { dlclose(handle) }
        guard let connSym = dlsym(handle, "CGSDefaultConnectionForThread") else {
            print("[ExternalState] CGSDefaultConnectionForThread not found")
            return nil
        }
        guard let spacesSym = dlsym(handle, "CGSCopySpacesForWindows") else {
            print("[ExternalState] CGSCopySpacesForWindows not found")
            return nil
        }

        let getConn = unsafeBitCast(connSym, to: CGSDefaultConnectionFunc.self)
        let getSpaces = unsafeBitCast(spacesSym, to: CGSCopySpacesForWindowsFunc.self)

        let conn = getConn()
        // mask: 1=current, 2=other, 4=fullscreen; 7=all
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let spacesArr = getSpaces(conn, 7, windowIDs) else { return nil }
        let spaces = spacesArr as [AnyObject]
        guard let first = spaces.first as? NSNumber else { return nil }
        return first.intValue
    }

    /// Find all open windows and save their positions/metadata to JSON in the app data folder.
    /// Saves all normal user-visible windows (layer 0, non-zero size). Filtering to darc-only happens on restore.
    func saveDarcWindowPositions() {
        // Use optionAll to include windows on all desktops/spaces, not just the current one
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            appendLog("launcher", "Save window positions: failed to get window list")
            print("[ExternalState] Failed to get window list")
            return
        }

        var darcWindows: [[String: Any]] = []

        for win in windowList {
            // Only include normal windows (layer 0) — skip menu bar, dock, system overlays
            let layer = (win[kCGWindowLayer as String] as? Int) ?? -1
            guard layer == 0 else { continue }

            // Skip zero-size or invisible windows
            let alpha = (win[kCGWindowAlpha as String] as? Double) ?? 0
            guard alpha > 0 else { continue }

            let bounds = win[kCGWindowBounds as String] as? [String: CGFloat]
            let width = bounds?["Width"] ?? 0
            let height = bounds?["Height"] ?? 0
            // Skip tiny helper windows (toolbars, tab strips, etc.)
            guard width > 100 && height > 100 else { continue }

            let ownerName = (win[kCGWindowOwnerName as String] as? String) ?? ""
            let ownerPID = win[kCGWindowOwnerPID as String] as? Int32

            // Skip system services (XPC helpers, etc.) — only keep windows from apps with a bundle ID
            if let pid = ownerPID {
                let app = NSRunningApplication(processIdentifier: pid)
                if app?.bundleIdentifier == nil { continue }
            }
            let windowName = (win[kCGWindowName as String] as? String) ?? ""
            let windowID = win[kCGWindowNumber as String] as? Int

            var entry: [String: Any] = [
                "window_id": windowID ?? -1,
                "owner_name": ownerName,
                "owner_pid": ownerPID ?? -1,
                "window_name": windowName,
                "layer": (win[kCGWindowLayer as String] as? Int) ?? 0,
                "alpha": (win[kCGWindowAlpha as String] as? Double) ?? 1.0,
            ]

            if let bounds {
                entry["x"] = bounds["X"] ?? 0
                entry["y"] = bounds["Y"] ?? 0
                entry["width"] = bounds["Width"] ?? 0
                entry["height"] = bounds["Height"] ?? 0
            }

            // Desktop/space number via private CGS API
            if let wid = windowID, let desktop = desktopForWindow(UInt32(wid)) {
                entry["desktop"] = desktop
            }

            // Process path from PID
            if let pid = ownerPID {
                let pathBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                defer { pathBuf.deallocate() }
                let ret = proc_pidpath(pid, pathBuf, 4096)
                if ret > 0 {
                    entry["process_path"] = String(cString: pathBuf)
                }
            }

            // Optional accessibility enrichment — may fail for some windows
            if let pid = ownerPID {
                let axApp = AXUIElementCreateApplication(pid)
                var axWindows: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &axWindows) == .success,
                   let windowList = axWindows as? [AXUIElement] {
                    // Try to find the matching AX window by position
                    for axWin in windowList {
                        var axPos: CFTypeRef?
                        var axSize: CFTypeRef?
                        AXUIElementCopyAttributeValue(axWin, kAXPositionAttribute as CFString, &axPos)
                        AXUIElementCopyAttributeValue(axWin, kAXSizeAttribute as CFString, &axSize)

                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        if let axPos, AXValueGetValue(axPos as! AXValue, .cgPoint, &pos),
                           let axSize, AXValueGetValue(axSize as! AXValue, .cgSize, &size) {
                            // Match by position (CGWindow coords should match AX coords)
                            let bx = bounds?["X"] ?? -99999
                            let by = bounds?["Y"] ?? -99999
                            if abs(pos.x - bx) < 2 && abs(pos.y - by) < 2 {
                                // Extract all available string/bool/number AX attributes
                                var attrNames: CFArray?
                                AXUIElementCopyAttributeNames(axWin, &attrNames)
                                if let names = attrNames as? [String] {
                                    for attr in names {
                                        var ref: CFTypeRef?
                                        guard AXUIElementCopyAttributeValue(axWin, attr as CFString, &ref) == .success,
                                              let val = ref else { continue }
                                        let key = "ax_\(attr)"
                                        if let s = val as? String { entry[key] = s }
                                        else if let b = val as? Bool { entry[key] = b }
                                        else if let n = val as? NSNumber { entry[key] = n.intValue }
                                        // Skip AXUIElement, AXValue (position/size already captured), arrays
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }

            darcWindows.append(entry)
        }

        // Save to JSON
        let outputURL = Self.appDataURL.appendingPathComponent("window_positions.json")
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: darcWindows, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: outputURL, options: .atomic)
            appendLog("launcher", "Saved \(darcWindows.count) Xe Computer window position(s) to \(outputURL.path)")
            print("[ExternalState] Saved \(darcWindows.count) Xe Computer window positions to \(outputURL.path)")
        } catch {
            appendLog("launcher", "Failed to save window positions: \(error)")
            print("[ExternalState] Failed to save window positions: \(error)")
        }
    }

    /// Restore darc window positions from the saved JSON file.
    /// This opens additional windows as needed (the first window already exists from app launch),
    /// then positions and resizes each window using the Accessibility API, and assigns desktop/space.
    func restoreDarcWindowPositions() {
        let inputURL = Self.appDataURL.appendingPathComponent("window_positions.json")
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            appendLog("launcher", "No saved window positions found")
            print("[ExternalState] No window_positions.json found")
            return
        }

        guard let data = try? Data(contentsOf: inputURL),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            appendLog("launcher", "Failed to parse window_positions.json")
            print("[ExternalState] Failed to parse window_positions.json")
            return
        }

        guard !entries.isEmpty else { return }
        guard darcRunning, let darcPID = darcApp?.processIdentifier else {
            appendLog("launcher", "Xe Computer is not running, cannot restore windows")
            print("[ExternalState] Xe Computer not running")
            return
        }

        let app = AXUIElementCreateApplication(darcPID)

        // Get current window count
        var windowCount: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowCount)
        let currentWindows = (windowCount as? [AXUIElement]) ?? []
        let neededExtra = entries.count - currentWindows.count

        // Open additional windows via AX "AXPress" on the menu bar or via AppleScript
        if neededExtra > 0 {
            for _ in 0..<neededExtra {
                openNewDarcWindow(app: app, pid: darcPID)
                Thread.sleep(forTimeInterval: 0.5)  // Wait for window to appear
            }
        }

        // Re-fetch windows after opening new ones
        var updatedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &updatedRef)
        let allWindows = (updatedRef as? [AXUIElement]) ?? []

        // Position each window according to saved data
        for (i, entry) in entries.enumerated() {
            guard i < allWindows.count else { break }
            let win = allWindows[i]

            // Set position
            if let x = entry["x"] as? CGFloat, let y = entry["y"] as? CGFloat {
                var point = CGPoint(x: x, y: y)
                if let posValue = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posValue)
                }
            }

            // Set size
            if let w = entry["width"] as? CGFloat, let h = entry["height"] as? CGFloat {
                var size = CGSize(width: w, height: h)
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeValue)
                }
            }

            // Move to desktop/space if saved — done after positioning via CGWindowIDs

        }

        // Now assign desktop/space using CGWindowIDs
        let cgWindowIDs = darcWindowIDs(pid: darcPID)
        for (i, entry) in entries.enumerated() {
            guard i < cgWindowIDs.count, let desktop = entry["desktop"] as? Int else { continue }
            moveWindowToSpace(windowID: cgWindowIDs[i], spaceID: desktop)
        }

        appendLog("launcher", "Restored \(min(entries.count, allWindows.count)) window position(s)")
        print("[ExternalState] Restored \(min(entries.count, allWindows.count)) window positions")
    }

    /// Open a new window in the Xe Computer app shim via its dock menu "New Window" item.
    private func openNewDarcWindow(app: AXUIElement, pid: Int32) {
        // Use AppleScript to click "New Window" in the app's dock menu
        let script = """
        tell application "System Events"
            tell process "Dock"
                set dockItems to every UI element of list 1
                repeat with dockItem in dockItems
                    try
                        if (value of attribute "AXIsApplicationRunning" of dockItem) is true then
                            set itemName to name of dockItem
                            if itemName is "Xe Computer" then
                                perform action "AXShowMenu" of dockItem
                                delay 0.3
                                click menu item "New Window" of menu 1 of dockItem
                                return
                            end if
                        end if
                    end try
                end repeat
            end tell
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error {
                print("[ExternalState] AppleScript new window error: \(error)")
                appendLog("launcher", "Failed to open new Xe Computer window: \(error)")
            }
        }
    }

    /// Get CGWindowIDs for the darc process
    private func darcWindowIDs(pid: Int32) -> [UInt32] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids: [UInt32] = []
        for win in windowList {
            guard let ownerPID = win[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
                  let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let wid = win[kCGWindowNumber as String] as? Int else { continue }
            ids.append(UInt32(wid))
        }
        return ids
    }

    /// Move a window to a specific space using private CGS APIs
    private func moveWindowToSpace(windowID: UInt32, spaceID: Int) {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else { return }
        defer { dlclose(handle) }

        typealias CGSDefaultConnectionFunc = @convention(c) () -> UInt32
        typealias CGSMoveWindowsToManagedSpaceFunc = @convention(c) (UInt32, CFArray, UInt64) -> Int32

        guard let connSym = dlsym(handle, "CGSDefaultConnectionForThread"),
              let moveSym = dlsym(handle, "CGSMoveWindowsToManagedSpace") else { return }

        let getConn = unsafeBitCast(connSym, to: CGSDefaultConnectionFunc.self)
        let moveWindows = unsafeBitCast(moveSym, to: CGSMoveWindowsToManagedSpaceFunc.self)

        let conn = getConn()
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        let result = moveWindows(conn, windowIDs, UInt64(spaceID))
        if result != 0 {
            print("[ExternalState] CGSMoveWindowsToManagedSpace failed with \(result) for window \(windowID) -> space \(spaceID)")
        }
    }

    /// Terminate and remove a named subprocess
    func terminateSubprocess(_ name: String) {
        if let process = subprocesses[name] {
            process.terminate()
            subprocesses.removeValue(forKey: name)
        }
        // Also kill posix_spawn'd browser process
        if name == "browser" && _browserPid > 0 {
            kill(_browserPid, SIGTERM)
            _browserPid = 0
        }
    }

    // MARK: - Per-profile overrides

    /// Returns the override URL for the given profile's Darc IWA, or nil if not set.
    func darcOverrideURL(forProfile profileName: String) -> String? {
        guard let overrides = settings.rawData?["overrides"] as? [String: Any],
              let profileOverrides = overrides[profileName] as? [String: Any],
              let darc = profileOverrides["darc"] as? [String: Any],
              let url = darc["url"] as? String, !url.isEmpty else { return nil }
        return url
    }

    /// Sets or clears the override URL for the given profile's Darc IWA.
    func setDarcOverrideURL(forProfile profileName: String, url: String?) {
        var dict = settings.rawData ?? [:]
        var overrides = dict["overrides"] as? [String: Any] ?? [:]
        var profileOverrides = overrides[profileName] as? [String: Any] ?? [:]
        var darc = profileOverrides["darc"] as? [String: Any] ?? [:]

        if let url, !url.isEmpty {
            darc["url"] = url
        } else {
            darc.removeValue(forKey: "url")
        }

        profileOverrides["darc"] = darc.isEmpty ? nil : darc
        overrides[profileName] = profileOverrides.isEmpty ? nil : profileOverrides
        dict["overrides"] = overrides.isEmpty ? nil : overrides
        settings = Settings(rawData: dict)
        saveSettings()
    }

    /// Returns the currently selected profile name, defaulting to "default".
    func selectedProfileName() -> String {
        (settings.rawData?["selected_profile"] as? String) ?? "default"
    }

    /// Select a profile by name. If Chrome is running it must be restarted externally.
    func selectProfile(_ name: String) {
        var dict = settings.rawData ?? [:]
        dict["selected_profile"] = name
        settings = Settings(rawData: dict)
        saveSettings()
    }

    /// Create a new profile folder from the bootstrap template (if available) and return an error string on failure.
    func createProfile(name: String) -> String? {
        let sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return "Profile name cannot be empty" }
        let profilePath = Self.appDataURL.appendingPathComponent("profiles/\(sanitized)", isDirectory: true)
        let fm = FileManager.default

        do {
            // Create the profile directory and Default subdirectory
            let defaultDir = profilePath.appendingPathComponent("Default", isDirectory: true)
            try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)

            // Copy base Preferences.json into the Default profile folder if available
            if let prefsURL = Bundle.main.resourceURL?.appendingPathComponent("Preferences.json"),
               fm.fileExists(atPath: prefsURL.path) {
                let destPrefs = defaultDir.appendingPathComponent("Preferences")
                try fm.copyItem(at: prefsURL, to: destPrefs)
                appendLog("launcher", "Created profile '\(sanitized)' with base Preferences")
            } else {
                appendLog("launcher", "Created empty profile '\(sanitized)' (no Preferences.json in bundle)")
            }

            // Copy base Local State into the profile root if available
            if let localStateURL = Bundle.main.resourceURL?.appendingPathComponent("Local State"),
               fm.fileExists(atPath: localStateURL.path) {
                let destLocalState = profilePath.appendingPathComponent("Local State")
                try fm.copyItem(at: localStateURL, to: destLocalState)
                appendLog("launcher", "Copied Local State to profile '\(sanitized)'")
            }
            updateChromeProfiles()
            return nil
        } catch {
            return "Failed to create profile: \(error.localizedDescription)"
        }
    }

    func startLegacyVM() -> String? { runColimaLogged(arguments: ["start", "-p", "darc"]) }
    func stopLegacyVM() -> String? { runColimaLogged(arguments: ["stop", "-p", "darc"]) }

    func startColimaVM(profileName: String) -> String? {
        if let err = ensureColimaProfile(profileName: profileName) { return err }
        return runColimaLogged(arguments: ["start", "-p", "\(Self.colimaProfilePrefix)\(profileName)"])
    }

    func stopColimaVM(profileName: String) -> String? {
        runColimaLogged(arguments: ["stop", "-p", "\(Self.colimaProfilePrefix)\(profileName)"])
    }

    private func ensureColimaProfile(profileName: String) -> String? {
        let profileDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".colima", isDirectory: true)
            .appendingPathComponent("\(Self.colimaProfilePrefix)\(profileName)", isDirectory: true)
        let dest = profileDir.appendingPathComponent("colima.yaml")
        let src = Self.appDataURL.appendingPathComponent("vms/\(profileName).yaml")

        guard FileManager.default.fileExists(atPath: src.path) else { return "VM config not found: \(src.path)" }

        do {
            try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: src, to: dest)
            return nil
        } catch {
            return "Failed to prepare colima profile: \(error.localizedDescription)"
        }
    }

    private func runColimaLogged(arguments: [String]) -> String? {
        guard let colimaPath = resolveExecutable(name: "colima") else { return "Colima not found" }
        let result = runCommand(colimaPath, arguments: arguments)
        result.output.split(separator: "\n").forEach { appendLog("colima", String($0)) }
        result.error.split(separator: "\n").forEach { appendLog("colima", String($0)) }
        updateColimaStatus(force: true)
        return result.exitCode == 0 ? nil : (result.error.isEmpty ? "colima command failed" : result.error)
    }



    /// Returns the currently selected Chrome variant.  Defaults to "helium" when no variant is saved.
    /// Returns `nil` if the selected variant is not installed — never silently falls back to another browser.
    func selectedChrome() -> InstalledChrome? {
        let minVersion = 145
        let savedVariant = settings.rawData?["selected_chrome_variant"] as? String ?? "helium"
        let eligible = installedChromes.filter { $0.isInstalled && ($0.version ?? 0) >= minVersion }
        return eligible.first(where: { $0.variant == savedVariant })
    }

    /// Select a Chrome variant by its variant key (e.g. "beta", "stable", "canary").
    /// If Chrome is currently running, it will be stopped and restarted with the new variant.
    func selectChromeVariant(_ variant: String) {
        var dict = settings.rawData ?? [:]
        dict["selected_chrome_variant"] = variant
        settings = Settings(rawData: dict)
        saveSettings()
    }

    func preferredChrome() -> InstalledChrome? {
        selectedChrome()
    }

    private func readChromeMajorVersion(appPath: String) -> Int? {
        let plistPath = "\(appPath)/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }
        let result = runCommand("/usr/bin/defaults", arguments: ["read", plistPath, "CFBundleShortVersionString"])
        guard result.exitCode == 0 else { return nil }
        let versionStr = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let major = versionStr.split(separator: ".").first.flatMap({ Int($0) }), major >= 100 {
            return major
        }
        // For browsers like Helium that use their own versioning, try --version to get the Chromium version
        let macosDir = "\(appPath)/Contents/MacOS"
        if let exec = try? FileManager.default.contentsOfDirectory(atPath: macosDir).first {
            let execPath = "\(macosDir)/\(exec)"
            let verResult = runCommand(execPath, arguments: ["--version"])
            if verResult.exitCode == 0 {
                // Parse "Chromium X.Y.Z" from output like "Helium 0.9.4.1 (Chromium 145.0.7632.116)"
                let output = verResult.output
                if let range = output.range(of: #"Chromium (\d+)"#, options: .regularExpression) {
                    let match = output[range]
                    let digits = match.drop(while: { !$0.isNumber })
                    return Int(digits)
                }
            }
        }
        return versionStr.split(separator: ".").first.flatMap { Int($0) }
    }

    private func resolveExecutable(name: String) -> String? {
        for c in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"] where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let which = runCommand("/usr/bin/which", arguments: [name])
        if which.exitCode == 0 {
            let t = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private func isColimaProfileRunning(_ name: String) -> Bool {
        colimaStatus.instances.contains { $0.name == name && $0.status == "Running" }
    }

    private func getSubfolders(at path: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return contents.filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: "\(path)/\(name)", isDirectory: &isDir) && isDir.boolValue
        }.sorted()
    }

    private func getYamlFiles(at path: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return contents.filter {
            let ext = ($0 as NSString).pathExtension.lowercased()
            return ext == "yaml" || ext == "yml"
        }.sorted()
    }

    /// Start a `log stream` process to capture NSLog/os_log output from the app shim.
    private func startAppShimLogStream(pid: pid_t) {
        terminateSubprocess("darc_log")
        do {
            subprocesses["darc_log"] = try spawnLongRunningProcess(
                executable: "/usr/bin/log",
                arguments: [
                    "stream",
                    "--predicate", "processID == \(pid)",
                    "--level", "info",
                    "--style", "compact"
                ],
                source: "app_shim"
            )
        } catch {
            appendLog("launcher", "Failed to start log stream for app_shim: \(error)")
        }
    }

    func spawnLongRunningProcess(executable: String, arguments: [String], source: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        // Remove launcher's bundle identifier so child processes (especially app_mode_loader)
        // can self-identify correctly during Chrome's code signature validation.
        env.removeValue(forKey: "__CFBundleIdentifier")
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { self?.appendLog(source, t) }
            }
        }

        process.terminationHandler = { [weak self] proc in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let exitCode = proc.terminationStatus
            self?.appendLog(source, "Process exited with code \(exitCode)")
            self?.appendLog("launcher", "\(source) process exited (code=\(exitCode))")
            print("[ExternalState] \(source) process exited (code=\(exitCode))")
        }

        try process.run()
        return process
    }

    private func runCommand(_ command: String, arguments: [String]) -> (output: String, error: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env

        let out = Pipe(); let err = Pipe()
        process.standardOutput = out; process.standardError = err

        do {
            try process.run()
            process.waitUntilExit()
            return (
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                process.terminationStatus
            )
        } catch {
            return ("", error.localizedDescription, -1)
        }
    }

}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value } }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unable to decode value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unable to encode value"))
        }
    }
}
