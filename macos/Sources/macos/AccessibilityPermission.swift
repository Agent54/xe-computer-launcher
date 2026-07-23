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

        // Show our non-floating companion panel first so the system prompt is
        // never obscured by it.
        await Task.yield()
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        for _ in 0..<120 {
            if AXIsProcessTrusted() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let isTrusted = AXIsProcessTrusted()
        closeSetupProgress()
        return isTrusted
    }
}
