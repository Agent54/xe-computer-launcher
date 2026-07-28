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

        for _ in 0..<120 {
            if AXIsProcessTrusted() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        let isTrusted = AXIsProcessTrusted()
        closeSetupProgress()
        return isTrusted
    }
}
