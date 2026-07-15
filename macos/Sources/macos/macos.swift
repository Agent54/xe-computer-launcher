import AppKit

@main
struct MacOSApp {
    static func main() {
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var didFinishNormalStartup = false
    private var statusItem: NSStatusItem?
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
    private var legacyVMItem: NSMenuItem?
    private var legacyVMStartItem: NSMenuItem?
    private var legacyVMStopItem: NSMenuItem?
    private var systemVMItem: NSMenuItem?
    private var systemVMStartItem: NSMenuItem?
    private var systemVMStopItem: NSMenuItem?
    private var appVMItem: NSMenuItem?
    private var appVMStartItem: NSMenuItem?
    private var appVMStopItem: NSMenuItem?
    private var runAtStartupItem: NSMenuItem?
    private var bindCapslockItem: NSMenuItem?
    private var hideDockIconItem: NSMenuItem?
    private var openAppDataFolderItem: NSMenuItem?
    private var openAppDataFolderSeparator: NSMenuItem?

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

        // Permission onboarding must not depend on whether downloadable assets
        // or an existing Darc app shim are already present.
        Task { @MainActor [weak self] in
            _ = await AccessibilityPermission.requestIfNeeded()
            self?.startBackgroundInitialization()
        }
    }

    private func startBackgroundInitialization() {
        // Do expensive init off main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let state = ExternalState.shared
            state.updateAll()

            if !state.isColimaInstalled {
                var installationError: String?

                if state.isHomebrewInstalled {
                    let progressReady = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        showSetupProgress(message: "Installing a required VM dependency", allowsCancellation: false)
                        updateSetupProgress(status: "Installing Colima with Homebrew…")
                        setSetupProgressIndeterminate(true)
                        progressReady.signal()
                    }
                    progressReady.wait()

                    installationError = state.installColima()

                    let progressClosed = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        closeSetupProgress()
                        progressClosed.signal()
                    }
                    progressClosed.wait()
                } else {
                    installationError = state.installColima()
                }

                if let installationError {
                    let alertClosed = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        self.showColimaInstallationError(installationError)
                        alertClosed.signal()
                    }
                    alertClosed.wait()
                } else {
                    state.refreshRuntimeStateFromSystemTruth(force: true)
                }
            }

            // Check for zombie Helium/Darc processes before launching
            let zombies = state.findZombieProcesses()
            if !zombies.isEmpty {
                let sem = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    self.showZombieAlert(zombies)
                    sem.signal()
                }
                sem.wait()
            }

            _ = state.launchBrowserStack()
            Task { @MainActor in self.renderMenuLabels() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When the app is launched again while already running, bring Darc to foreground or start it
        let state = ExternalState.shared
        if state.darcRunning {
            if let app = state.darcAppRef {
                app.activate()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                _ = state.launchBrowserStack()
                Task { @MainActor in self.renderMenuLabels() }
            }
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStateRefreshLoop()
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
            if let resourceURL = Bundle.main.resourceURL,
               let icon = NSImage(contentsOf: resourceURL.appendingPathComponent("status-icon.png")) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(
                    systemSymbolName: "desktopcomputer",
                    accessibilityDescription: "Xe Computer"
                )
                button.image?.size = NSSize(width: 18, height: 18)
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        // Profile entries are inserted dynamically between here and the New Profile item
        profileInsertionIndex = menu.numberOfItems
        rebuildProfileItems()

        let newProfileItem = NSMenuItem(title: "New Profile...", action: #selector(newProfileAction), keyEquivalent: "")
        newProfileItem.target = self
        menu.addItem(newProfileItem)

        menu.addItem(.separator())
        legacyVMItem = buildSubmenu(parent: menu, title: "Legacy VM", startSelector: #selector(legacyVMStartAction), stopSelector: #selector(legacyVMStopAction), startRef: &legacyVMStartItem, stopRef: &legacyVMStopItem)
        systemVMItem = buildSubmenu(parent: menu, title: "System VM", startSelector: #selector(systemVMStartAction), stopSelector: #selector(systemVMStopAction), startRef: &systemVMStartItem, stopRef: &systemVMStopItem)
        appVMItem = buildSubmenu(parent: menu, title: "App VM", startSelector: #selector(appVMStartAction), stopSelector: #selector(appVMStopAction), startRef: &appVMStartItem, stopRef: &appVMStopItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Save Window Positions", action: #selector(darcSaveWindowPositionsAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restore Window Positions", action: #selector(darcRestoreWindowPositionsAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "System Logs", action: #selector(showLogsAction), keyEquivalent: ""))

        let appDataSeparator = NSMenuItem.separator()
        appDataSeparator.isHidden = true
        menu.addItem(appDataSeparator)
        openAppDataFolderSeparator = appDataSeparator

        let appDataItem = NSMenuItem(title: "Open App Data Folder", action: #selector(openAppDataFolderAction), keyEquivalent: "")
        appDataItem.isHidden = true
        menu.addItem(appDataItem)
        openAppDataFolderItem = appDataItem

        menu.addItem(.separator())

        runAtStartupItem = NSMenuItem(title: "Run at Startup", action: #selector(runAtStartupAction), keyEquivalent: "")
        bindCapslockItem = NSMenuItem(title: "Bind to Capslock", action: #selector(bindCapslockAction), keyEquivalent: "")
        hideDockIconItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(hideDockIconAction), keyEquivalent: "")
        if let runAtStartupItem { menu.addItem(runAtStartupItem) }
        if let bindCapslockItem { menu.addItem(bindCapslockItem) }
        if let hideDockIconItem { menu.addItem(hideDockIconItem) }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About", action: #selector(aboutAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q"))

        setTargets(for: menu)
        statusItem?.menu = menu
    }

    private func buildSubmenu(parent: NSMenu, title: String, startSelector: Selector, stopSelector: Selector, startRef: inout NSMenuItem?, stopRef: inout NSMenuItem?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let startItem = NSMenuItem(title: "Start", action: startSelector, keyEquivalent: "")
        let stopItem = NSMenuItem(title: "Stop", action: stopSelector, keyEquivalent: "")
        submenu.addItem(startItem)
        submenu.addItem(stopItem)
        item.submenu = submenu
        parent.addItem(item)
        startRef = startItem
        stopRef = stopItem
        return item
    }

    private var chromeVariantItems: [NSMenuItem] = []
    private var chromeSubmenu: NSMenu?



    private var chromeVariantSeparator: NSMenuItem?

    private func refreshChromeMenuOptions(in submenu: NSMenu) {
        // Remove old variant items
        for old in chromeVariantItems { submenu.removeItem(old) }
        chromeVariantItems.removeAll()
        if let sep = chromeVariantSeparator { submenu.removeItem(sep); chromeVariantSeparator = nil }

        let state = ExternalState.shared
        let minVersion = 145
        let showVariants = NSEvent.modifierFlags.contains(.option)

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

            // Darc submenu
            let darcSub = NSMenuItem(title: "Darc", action: nil, keyEquivalent: "")
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
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        lastOptionKeyState = optionHeld
        updateOptionOnlyMenuItems(optionHeld: optionHeld)
        // Refresh state in background, then start polling while menu is open
        DispatchQueue.global(qos: .utility).async { [weak self] in
            ExternalState.shared.refreshRuntimeStateFromSystemTruth()
            Task { @MainActor [weak self] in self?.renderMenuLabels() }
        }
        startStateRefreshLoop()
        // Monitor Option key press/release while menu is open to toggle variant items.
        // NSMenu runs its own event tracking loop so neither addLocalMonitor nor
        // addGlobalMonitor reliably fires during nested submenu tracking.
        // Use a polling timer instead.
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let optionHeld = NSEvent.modifierFlags.contains(.option)
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
        openAppDataFolderItem?.isHidden = !optionHeld
        openAppDataFolderSeparator?.isHidden = !optionHeld
        statusItem?.menu?.update()
    }

    // MARK: - Render (reads cached state only, no I/O)

    private func serviceTitle(_ name: String, key: String, running: Bool) -> String {
        if pendingServices.contains(key) { return "\(name) ⏳" }
        return running ? "\(name) 🟢" : name
    }

    private func renderMenuLabels() {
        let state = ExternalState.shared

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
        darcItem?.title = serviceTitle("Darc", key: "darc", running: state.darcRunning)
        let chromeName = state.selectedChrome()?.name ?? "Chrome Engine"
        chromeItem?.title = serviceTitle(chromeName, key: "chrome", running: state.chromeRunning)

        let darcPending = pendingServices.contains("darc")
        let chromePending = pendingServices.contains("chrome")

        darcStartItem?.isEnabled = !state.darcRunning && !darcPending
        darcStopItem?.isEnabled = state.darcRunning && !darcPending
        chromeStartItem?.isEnabled = !state.chromeRunning && !chromePending
        chromeStopItem?.isEnabled = state.chromeRunning && !chromePending
        chromeHeadlessItem?.state = state.boolSetting("chrome_headless", default: false) ? .on : .off

        // Refresh chrome variant options (only adds items when Option key is held)
        if let chromeSubmenu {
            refreshChromeMenuOptions(in: chromeSubmenu)
        }

        // VM items
        legacyVMItem?.title = serviceTitle("Legacy VM", key: "legacyVM", running: state.legacyVMRunning)
        systemVMItem?.title = serviceTitle("System VM", key: "systemVM", running: state.systemVMRunning)
        appVMItem?.title = serviceTitle("App VM", key: "appVM", running: state.appVMRunning)

        let legacyPending = pendingServices.contains("legacyVM")
        let systemPending = pendingServices.contains("systemVM")
        let appPending = pendingServices.contains("appVM")

        legacyVMStartItem?.isEnabled = !state.legacyVMRunning && !legacyPending
        legacyVMStopItem?.isEnabled = state.legacyVMRunning && !legacyPending
        systemVMStartItem?.isEnabled = !state.systemVMRunning && !systemPending
        systemVMStopItem?.isEnabled = state.systemVMRunning && !systemPending
        appVMStartItem?.isEnabled = !state.appVMRunning && !appPending
        appVMStopItem?.isEnabled = state.appVMRunning && !appPending

        runAtStartupItem?.state = state.boolSetting("run_at_startup", default: false) ? .on : .off
        bindCapslockItem?.state = state.boolSetting("bind_capslock", default: false) ? .on : .off
        hideDockIconItem?.state = state.boolSetting("hide_dock_icon", default: false) ? .on : .off

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
            ExternalState.shared.setBoolSetting("darc_was_running", true)
        }
    }

    @objc private func darcStopAction() {
        runServiceAction("darc") {
            ExternalState.shared.stopDarc()
            ExternalState.shared.setBoolSetting("darc_was_running", false)
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

    @objc private func darcOverrideURLAction() {
        let state = ExternalState.shared
        let profileName = state.selectedProfileName()
        let currentURL = state.darcOverrideURL(forProfile: profileName) ?? ""

        let alert = NSAlert()
        alert.messageText = "Override Darc URL"
        alert.informativeText = "Enter the base URL for the Darc IWA.\nLeave empty to use the default local bundle.\nThe URL will be validated by checking /.well-known/manifest.webmanifest"
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
            ExternalState.shared.setBoolSetting("chrome_was_running", true)
        }
    }

    @objc private func chromeStopAction() {
        runServiceAction("chrome") {
            ExternalState.shared.stopChrome()
            ExternalState.shared.setBoolSetting("chrome_was_running", false)
            ExternalState.shared.setBoolSetting("darc_was_running", false)
        }
    }

    @objc private func chromeHeadlessAction() {
        let current = ExternalState.shared.boolSetting("chrome_headless", default: false)
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

    @objc private func legacyVMStartAction() {
        runServiceAction("legacyVM") { _ = ExternalState.shared.startLegacyVM() }
    }

    @objc private func legacyVMStopAction() {
        runServiceAction("legacyVM") { _ = ExternalState.shared.stopLegacyVM() }
    }

    @objc private func systemVMStartAction() {
        runServiceAction("systemVM") { _ = ExternalState.shared.startColimaVM(profileName: "system") }
    }

    @objc private func systemVMStopAction() {
        runServiceAction("systemVM") { _ = ExternalState.shared.stopColimaVM(profileName: "system") }
    }

    @objc private func appVMStartAction() {
        runServiceAction("appVM") { _ = ExternalState.shared.startColimaVM(profileName: "apps") }
    }

    @objc private func appVMStopAction() {
        runServiceAction("appVM") { _ = ExternalState.shared.stopColimaVM(profileName: "apps") }
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
        applyDockIconPreference()
        renderMenuLabels()
    }

    private func configureApplicationIdentity() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Xe Computer"
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

    @objc private func aboutAction() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quitAction() {
        // Save running state before stopping so it can be restored on next launch
        let state = ExternalState.shared
        state.setBoolSetting("darc_was_running", state.darcRunning)
        state.setBoolSetting("chrome_was_running", state.chromeRunning)
        state.stopChrome()  // stopChrome calls stopDarc internally
        NSApp.terminate(nil)
    }

    // MARK: - Zombie process alert

    private func showColimaInstallationError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Colima Installation Required"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showZombieAlert(_ zombies: [ExternalState.ZombieProcess]) {
        guard !zombies.isEmpty else { return }

        let descriptions = zombies.map { z in
            var desc = "\(z.name) (pid \(z.pid))"
            if let profile = z.profileDir {
                // Show just the profile folder name for brevity
                let profileName = (profile as NSString).lastPathComponent
                desc += " — profile: \(profileName)"
            }
            return desc
        }

        let alert = NSAlert()
        alert.messageText = "Stale Browser Processes Found"
        alert.informativeText = "The following Helium/Darc processes from a previous session are still running:\n\n"
            + descriptions.joined(separator: "\n")
            + "\n\nWould you like to terminate them before launching?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill All")
        alert.addButton(withTitle: "Ignore")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            ExternalState.shared.killZombieProcesses(zombies)
            // Wait briefly for processes to exit
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Background state refresh

    private func startStateRefreshLoop() {
        guard stateRefreshTimer == nil else { return }
        stateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // Re-render from cached/computed state + refresh colima in background
            Task { @MainActor [weak self] in self?.renderMenuLabels() }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                ExternalState.shared.refreshRuntimeStateFromSystemTruth()
                Task { @MainActor [weak self] in self?.renderMenuLabels() }
            }
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
