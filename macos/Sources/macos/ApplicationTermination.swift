import AppKit

@MainActor
enum ApplicationTermination {
    static func request() {
        // terminateLater enters a nested AppKit event loop. A Swift task or
        // main-queue block cannot drain more main-actor work while inside it,
        // so let a run-loop timer enter termination after the caller returns.
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
}
