import AppKit

@MainActor
enum LauncherSetup {
    private static let settingKey = "compose_storage_path"

    static func needsChoice() -> Bool {
        needsChoice(settings: ExternalState.shared.settings.rawData)
    }

    static func needsChoice(settings: [String: Any]?) -> Bool {
        let path = settings?[settingKey] as? String
        return path?.isEmpty != false || WorkerdPorts.needsPortChoice(settings)
    }

    /// Ask for first-run choices before starting Compose. Cancelling leaves
    /// setup incomplete so the user can try again on the next launch.
    static func chooseIfNeeded() throws -> URL? {
        let state = ExternalState.shared
        if let path = state.stringSetting(settingKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try prepare(url)
            if WorkerdPorts.needsPortChoice(state.settings.rawData) && !choosePortsForExistingStorage() {
                return nil
            }
            return url
        }

        while true {
            let alert = NSAlert()
            alert.messageText = "Choose user data storage"
            let portsAlreadyConfigured = !WorkerdPorts.needsPortChoice(state.settings.rawData)
            let standardPortsAvailable = standardPortsSelectable()
            let defaultPortWarnings = portsAlreadyConfigured ? [] : WorkerdPorts(settings: nil).bindingWarnings()
            alert.informativeText = "Choose a folder for your Compose projects and their files. The default is a stacks folder in Xe Launcher's app data directory:\n\n\(ComposeServerPaths.stacksURL.path)\n\n" +
                (portsAlreadyConfigured
                    ? "Your existing local app port settings will be kept."
                    : standardPortsAvailable
                    ? "Local apps use ports 5196 (HTTP) and 5194 (HTTPS) unless you select standard web ports below. Choosing 80/443 adds a background port helper. When macOS asks, choose Allow and authenticate as an administrator; 80/443 will not work until you restart Xe Launcher after approval."
                    : "Ports 80/443 are unavailable. Local apps will use ports 5196 (HTTP) and 5194 (HTTPS).") +
                (defaultPortWarnings.isEmpty ? "" : "\n\nDefault ports are currently unavailable: \(defaultPortWarnings.joined(separator: " "))")
            let standardPortsCheckbox: NSButton? = standardPortsAvailable && !portsAlreadyConfigured
                ? NSButton(checkboxWithTitle: "Use ports 80/443 for local apps (requires administrator approval)", target: nil, action: nil)
                : nil
            if let standardPortsCheckbox {
                standardPortsCheckbox.frame = NSRect(x: 0, y: 0, width: 440, height: 24)
                alert.accessoryView = standardPortsCheckbox
            }
            alert.addButton(withTitle: "Use Default Folder")
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Not Now")
            NSApp.activate(ignoringOtherApps: true)

            let url: URL
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                url = ComposeServerPaths.stacksURL
            case .alertSecondButtonReturn:
                let panel = NSOpenPanel()
                panel.title = "Choose user data storage"
                panel.message = "Select a folder for your Compose projects and their files."
                panel.prompt = "Use This Folder"
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = true
                panel.directoryURL = ComposeServerPaths.stacksURL
                guard panel.runModal() == .OK, let selected = panel.url else { continue }
                url = selected
            default:
                return nil
            }

            do {
                try prepare(url)
                let wantsStandardPorts = standardPortsCheckbox?.state == .on
                if !portsAlreadyConfigured {
                    if wantsStandardPorts && !standardPortsSelectable() {
                        showPortWarning("Ports 80/443 Became Unavailable", "Choose ports again; Xe Launcher will not silently switch to 5196/5194.")
                        continue
                    }
                    if !wantsStandardPorts {
                        let warnings = WorkerdPorts(settings: nil).bindingWarnings()
                        if !warnings.isEmpty {
                            showPortWarning("Default Ports Are Unavailable", warnings.joined(separator: "\n"))
                            continue
                        }
                    }
                }
                state.setStringSetting(settingKey, url.path)
                if !portsAlreadyConfigured { state.setAppPorts(useStandardPorts: wantsStandardPorts) }
                return url
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
    }

    private enum PortChoice {
        case standard
        case defaults
        case retry
        case notNow
    }

    private static func choosePortsForExistingStorage() -> Bool {
        let state = ExternalState.shared
        while true {
            let standardAvailable = standardPortsSelectable()
            let defaultWarnings = WorkerdPorts(settings: nil).bindingWarnings()
            let alert = NSAlert()
            alert.messageText = "Choose local app ports"
            alert.informativeText = "Your existing user data folder is unchanged. This Xe Launcher version needs a port choice for local app domains. Ports 80/443 require approval of the background helper and a restart.\n\n" +
                (defaultWarnings.isEmpty ? "Ports 5196/5194 are available as the custom-port default."
                    : "Ports 5196/5194 are unavailable: \(defaultWarnings.joined(separator: " "))")
            var choices: [PortChoice] = []
            if standardAvailable {
                alert.addButton(withTitle: "Use ports 80/443")
                choices.append(.standard)
            }
            if defaultWarnings.isEmpty {
                alert.addButton(withTitle: "Use ports 5196/5194")
                choices.append(.defaults)
            }
            if choices.isEmpty {
                alert.addButton(withTitle: "Retry")
                choices.append(.retry)
            }
            alert.addButton(withTitle: "Not Now")
            choices.append(.notNow)
            NSApp.activate(ignoringOtherApps: true)
            let index = Int(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            guard choices.indices.contains(index) else { return false }
            switch choices[index] {
            case .standard:
                guard standardPortsSelectable() else {
                    showPortWarning("Ports 80/443 Became Unavailable", "Choose ports again after freeing them.")
                    continue
                }
                state.setAppPorts(useStandardPorts: true)
                return true
            case .defaults:
                let warnings = WorkerdPorts(settings: nil).bindingWarnings()
                guard warnings.isEmpty else {
                    showPortWarning("Default Ports Became Unavailable", warnings.joined(separator: "\n"))
                    continue
                }
                state.setAppPorts(useStandardPorts: false)
                return true
            case .retry:
                continue
            case .notNow:
                return false
            }
        }
    }

    private static func showPortWarning(_ title: String, _ detail: String) {
        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = title
        warning.informativeText = detail
        warning.runModal()
    }

    private static func standardPortsSelectable() -> Bool {
        // Once approved, launchd owns these listeners for our helper. A bind
        // probe sees them as occupied even though Xe Launcher can use them.
        PrivilegedPortService.status == .enabled || WorkerdPorts.standardPortsAvailable()
    }

    private static func prepare(_ url: URL) throws {
        let socketURL = url.appendingPathComponent("compose.sock")
        guard socketURL.path.utf8.count < 104 else {
            throw ComposeServerError.socketPathTooLong(socketURL.path)
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
