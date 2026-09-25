import AppKit
import ApplicationServices

/// Coordinates first-run Accessibility onboarding independently of asset and
/// app-shim installation state.
@MainActor
enum AccessibilityPermission {
    private static let trustProbeArgument = "--xe-accessibility-trust-probe"
    private static let relaunchAttemptedArgument = "--xe-accessibility-relaunch-attempted"

    static func requestIfNeeded() async -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        showSetupProgress(
            message: "",
            placement: .topTrailing,
            allowsCancellation: false
        )
        updateSetupProgress(
            status: "Grant Accessibility access to Xe Launcher in System Settings. Setup will continue automatically."
        )
        setSetupProgressIndeterminate(true)

        // Show our non-floating companion panel first so the system prompt is
        // never obscured by it. The prompt's Open System Settings action must
        // be used instead of opening the privacy pane ourselves: otherwise the
        // unanswered system prompt remains queued and macOS may terminate the
        // app while permission is still pending.
        await Task.yield()
        NSApp.activate(ignoringOtherApps: true)
        // The imported SDK symbol is mutable global state and therefore
        // rejected by Swift 6 concurrency checking. Its documented value is
        // stable and safe to pass as the dictionary key.
        let promptKey = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        let canRelaunchInstalledApp = Bundle.main.bundleURL.pathExtension == "app"
            && (!ApplicationInstaller.isRunningFromDiskImage()
                || ProcessInfo.processInfo.arguments.contains("--xe-computer-installed-relaunch"))
            && !ProcessInfo.processInfo.arguments.contains(relaunchAttemptedArgument)
        var nextProbeAt = Date().addingTimeInterval(3)
        while !AXIsProcessTrusted() {
            if Task.isCancelled {
                closeSetupProgress()
                return false
            }
            // Some macOS versions keep returning the pre-approval TCC result
            // in the process that requested access. A fresh process can see
            // the grant; in that case reopen the installed app once so setup
            // advances without requiring the user to quit it manually.
            if canRelaunchInstalledApp && Date() >= nextProbeAt {
                nextProbeAt = Date().addingTimeInterval(5)
                if await freshProcessHasAccessibilityAccess(), !AXIsProcessTrusted() {
                    updateSetupProgress(status: "Accessibility access is enabled. Reopening Xe Launcher to continue setup…")
                    if await relaunchWithAccessibilityAccess() {
                        ExternalState.shared.appendLog("launcher", "Accessibility approval is visible to a new process; reopening to continue setup.")
                        NSApp.terminate(nil)
                        return false
                    }
                    ExternalState.shared.appendLog("launcher", "Could not reopen Xe Launcher after Accessibility approval; retrying.")
                    updateSetupProgress(status: "Accessibility access is enabled. Waiting for macOS to reopen Xe Launcher…")
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        closeSetupProgress()
        return true
    }

    private static func freshProcessHasAccessibilityAccess() async -> Bool {
        guard let executableURL = Bundle.main.executableURL else { return false }
        let probeArgument = trustProbeArgument
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [probeArgument]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    private static func relaunchWithAccessibilityAccess() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["--xe-computer-installed-relaunch", relaunchAttemptedArgument]

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }
}
