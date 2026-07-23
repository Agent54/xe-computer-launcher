import AppKit
import ApplicationServices

/// Coordinates first-run Accessibility onboarding independently of asset and
/// app-shim installation state.
@MainActor
enum AccessibilityPermission {
    static func requestIfNeeded() async -> Bool {
        guard !AXIsProcessTrusted() else { return true }

        showSetupProgress(
            message: "",
            placement: .topTrailing,
            allowsCancellation: false
        )
        updateSetupProgress(
            status: "Grant Accessibility access to Xe Computer in System Settings. Setup will continue automatically."
        )
        setSetupProgressIndeterminate(true)

        // Show an app-owned prompt rather than AXTrustedCheckOptionPrompt. The
        // system trust prompt is protected from Accessibility automation, so
        // an integration runner cannot inspect or press its button.
        await Task.yield()
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = "Xe Computer needs Accessibility access to manage its windows. Grant access in System Settings to continue setup."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }

        for _ in 0..<120 {
            if AXIsProcessTrusted() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let isTrusted = AXIsProcessTrusted()
        closeSetupProgress()
        return isTrusted
    }
}
