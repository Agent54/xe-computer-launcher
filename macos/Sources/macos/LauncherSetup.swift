import AppKit

@MainActor
enum LauncherSetup {
    private static let settingKey = "compose_storage_path"

    /// Ask for first-run choices before starting Compose. Cancelling leaves
    /// setup incomplete so the user can try again on the next launch.
    static func chooseIfNeeded() throws -> URL? {
        let state = ExternalState.shared
        if let path = state.stringSetting(settingKey), !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try prepare(url)
            return url
        }

        while true {
            let alert = NSAlert()
            alert.messageText = "Choose user data storage"
            let standardPortsAvailable = standardPortsSelectable()
            alert.informativeText = "Choose a folder for your Compose projects and their files. The default is a stacks folder in Xe Launcher's app data directory:\n\n\(ComposeServerPaths.stacksURL.path)\n\n" +
                (standardPortsAvailable
                    ? "Local apps use ports 5196 (HTTP) and 5194 (HTTPS) unless you select standard web ports below."
                    : "Ports 80/443 are unavailable. Local apps will use ports 5196 (HTTP) and 5194 (HTTPS).")
            let standardPortsCheckbox: NSButton? = standardPortsAvailable
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
                let useStandardPorts = wantsStandardPorts && standardPortsSelectable()
                state.setInitialStorageAndPorts(path: url.path, useStandardPorts: useStandardPorts)
                if wantsStandardPorts && !useStandardPorts {
                    let warning = NSAlert()
                    warning.alertStyle = .warning
                    warning.messageText = "Standard Ports Became Unavailable"
                    warning.informativeText = "Xe Launcher will use ports 5196 and 5194 instead."
                    warning.runModal()
                }
                return url
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
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
