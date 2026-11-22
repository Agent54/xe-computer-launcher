import Testing
@testable import macos

struct SystemLogSeverityTests {
    @Test(arguments: [
        "browser process exited (code=-1)",
        "browser process exited (code=12)",
        "Browser shutdown finished (stopped=false) in 15.0s",
        "Shutdown exceeded 60 seconds; terminating after forced process cleanup",
        "Could not save System Logs: disk full",
        "Chrome start failed: file missing",
        "[123:456:1103/010000:ERROR:net/cert.cc:25] certificate failure",
        "level=error msg=\"startup failed\"",
        "{\"level\":\"error\",\"message\":\"failed\"}",
        "workerd exited unexpectedly (1); it will be restarted.",
    ])
    func recognizesErrors(line: String) {
        #expect(SystemLogSeverity.classify(source: "launcher", line: line) == .error)
    }

    @Test(arguments: [
        "Chrome process group did not exit after Browser.close (10.0s); sending SIGTERM",
        "Chrome process group did not exit after SIGTERM (3.0s); sending SIGKILL",
        "Warning: could not remove the replaced Helium directory",
        "level=warn msg=\"retrying\"",
        "[123:456:1103/010000:WARNING:browser.cc:25] retrying",
    ])
    func recognizesWarnings(line: String) {
        #expect(SystemLogSeverity.classify(source: "launcher", line: line) == .warning)
    }

    @Test(arguments: [
        "browser process exited (code=0)",
        "Process exited with code 0",
        "Chrome process group exited after Browser.close",
        "Browser shutdown finished (stopped=true) in 0.5s",
        "Shutdown complete in 0.6s",
        "Loaded error reporting configuration",
        "GET https://example.com/error-page 200",
    ])
    func ordinaryLogsDoNotRaiseWarnings(line: String) {
        #expect(SystemLogSeverity.classify(source: "launcher", line: line) == .info)
    }
}
