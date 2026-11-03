import Darwin
import Foundation

enum BrowserShutdown {
    @discardableResult
    static func stop(
        processGroup: pid_t,
        transport: CDPTransport,
        gracefulTimeout: TimeInterval = 10,
        terminationTimeout: TimeInterval = 3,
        killTimeout: TimeInterval = 2,
        log: (String) -> Void = { _ in }
    ) -> Bool {
        // Keep the debugging pipe and storage helpers alive until Chromium has
        // finished shutdown. Closing the pipe and immediately signalling the
        // whole group races profile writes and records an unclean browser exit.
        defer { transport.stop() }
        guard processGroup > 0 else { return true }
        guard !hasExited(processGroup) else { return true }

        log("Requesting graceful Chrome shutdown via Browser.close")
        // Shutdown must bypass sendCDP's startup-cancellation guard. A missing
        // reply is normal if Chromium disconnects while handling Browser.close;
        // process exit, rather than the reply, determines completion.
        _ = transport.command(method: "Browser.close", params: [:], sessionID: nil, timeout: 1)
        if waitForExit(processGroup, timeout: gracefulTimeout) {
            log("Chrome process group exited after Browser.close")
            return true
        }

        log("Chrome process group did not exit after Browser.close (\(gracefulTimeout)s); sending SIGTERM")
        kill(-processGroup, SIGTERM)
        if waitForExit(processGroup, timeout: terminationTimeout) { return true }

        log("Chrome process group did not exit after SIGTERM (\(terminationTimeout)s); sending SIGKILL")
        kill(-processGroup, SIGKILL)
        return waitForExit(processGroup, timeout: killTimeout)
    }

    private static func hasExited(_ processGroup: pid_t) -> Bool {
        kill(-processGroup, 0) != 0 && errno == ESRCH
    }

    private static func waitForExit(_ processGroup: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasExited(processGroup), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return hasExited(processGroup)
    }
}
