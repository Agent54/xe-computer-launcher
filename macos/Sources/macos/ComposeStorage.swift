import AppKit

@MainActor
enum ComposeStorage {
    private static let settingKey = "compose_storage_path"

    /// Ask once, before starting Compose. Cancelling leaves the choice unset
    /// so the user can choose storage the next time they launch the app.
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
            alert.informativeText = "Choose a folder for your Compose projects and their files. The default is a stacks folder in Xe Launcher's app data directory:\n\n\(ComposeServerPaths.stacksURL.path)"
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
                state.setStringSetting(settingKey, url.path)
                return url
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
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
