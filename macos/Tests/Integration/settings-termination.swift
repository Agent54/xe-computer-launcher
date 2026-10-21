import AppKit

/// Exercise the Quit Now handoff after async disk-settings work without
/// starting the launcher's services or touching the user's VM and settings.
@MainActor
final class TerminationDelegate: NSObject, NSApplicationDelegate {
    private var taskReturned = false
    private var cleanupFinished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A dispatch watchdog still fires if a nested AppKit event loop blocks
        // every main-actor task, including a Task.sleep-based shutdown timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("FAIL: async settings quit blocked shutdown\n", stderr)
            _exit(1)
        }
        Task { @MainActor in
            // Disk settings reaches Quit Now after awaiting the VM status.
            await Task.yield()
            ApplicationTermination.request()
            taskReturned = true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard taskReturned else {
            fputs("FAIL: termination entered before the settings task returned\n", stderr)
            _exit(1)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            cleanupFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard cleanupFinished else { _exit(1) }
        print("PASS: async settings quit completed main-actor shutdown")
    }
}

@main
struct SettingsTerminationTest {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = TerminationDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
