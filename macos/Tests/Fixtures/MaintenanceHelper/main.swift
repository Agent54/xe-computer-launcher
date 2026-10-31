import Foundation
import Darwin
import LauncherMaintenance

// SwiftPM links this fixture and the launcher against the same maintenance
// library. Only these disposable operations differ from the real entry point.
let arguments = CommandLine.arguments
if arguments.count == 1 {
    let lifecycle = try LauncherLifecycle(directoryURL: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("lifecycle"))
    defer { withExtendedLifetime(lifecycle) {} }
    try Data("relaunched".utf8).write(to: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("relaunched"))
    exit(0)
}
guard arguments.count >= 4 else { exit(2) }
let role = arguments[1]
let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
let mode = arguments[3]
let dataURL = root.appendingPathComponent("data", isDirectory: true)
let lockURL = root.appendingPathComponent("lifecycle", isDirectory: true)
let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
let executable = appURL.appendingPathComponent("Contents/MacOS/fixture")

do {
    if role == "host" {
        let lifecycle = try LauncherLifecycle(directoryURL: lockURL)
        let data = try AnchoredDirectory(dataURL)
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: appURL, executableURL: executable)
        let action: ApplicationMaintenance.Action = mode == "restart" ? .restart : .uninstall
        let request = ApplicationMaintenance.Request(action: action, nonce: UUID().uuidString, data: data.identity,
                                                     lifecycle: lifecycle.directory.identity, bundle: bundle)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: arguments[0])
        helper.arguments = ["worker", root.path, mode, mode == "wrong-nonce" ? "wrong" : request.nonce, String(getpid())]
        let handoff = try await ApplicationMaintenance.startHelper(helper, request: request, lifecycle: lifecycle)
        let failures: [String] = ShutdownResult.Component.allCases.contains { $0.rawValue + "-failure" == mode } ? [mode] : []
        let stopped = Set(ShutdownResult.Component.allCases.filter { $0.rawValue + "-failure" != mode })
        if mode == "no-commit" { handoff.cancel(); exit(0) }
        if mode == "parent-crash" { withExtendedLifetime(handoff) { exit(0) } }
        if mode == "invalid-commit" {
            _ = try await handoff.exchange(.commit(ShutdownResult(stopped: [], failures: [])))
            exit(0)
        }
        do { try await handoff.authorize(ShutdownResult(stopped: stopped, failures: failures)) }
        catch { handoff.cancel(); exit(0) }
        if mode == "hold" {
            // Tell the test that readiness and commit were acknowledged, then
            // retain the lifetime channel until the explicit exit instruction.
            try FileHandle.standardOutput.write(contentsOf: Data("committed\n".utf8))
            _ = try FileHandle.standardInput.read(upToCount: 1)
        }
        withExtendedLifetime(handoff) { exit(0) }
    } else if role == "worker" {
        guard arguments.count == 6, getppid() == pid_t(arguments[5]) else { exit(2) }
        if mode == "startup-failure" { exit(3) }
        if mode == "unresponsive-startup" {
            try Data().write(to: root.appendingPathComponent("startup-entered"))
            try await Task.sleep(for: .seconds(20))
            exit(3)
        }
        let action: ApplicationMaintenance.Action = mode == "restart" ? .restart : .uninstall
        let bundle = try ApplicationMaintenance.BundleIdentity.capture(bundleURL: appURL, executableURL: executable)
        try ApplicationMaintenance.serve(action: action, nonce: arguments[4], dataURL: dataURL,
            lifecycleURL: lockURL, bundle: bundle, perform: { request, data in
                if request.action == .restart {
                    let open = Process()
                    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    open.arguments = ["-n", appURL.path]
                    try ApplicationMaintenance.runBounded(open, timeout: 5)
                } else {
                    if mode == "hold-operation" {
                        try Data().write(to: root.appendingPathComponent("operation-entered"))
                        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                    }
                    let archive = try ApplicationMaintenance.archiveData(in: data)
                    try Data(archive.path.utf8).write(to: root.appendingPathComponent("archived"))
                    let trash = root.appendingPathComponent("Trash")
                    if mode == "trash-failure" { try Data().write(to: trash) }
                    try ApplicationMaintenance.trashApprovedBundle(request.bundle, trashURL: trash)
                }
            })
        try Data().write(to: root.appendingPathComponent("completed"))
    } else { exit(2) }
} catch {
    try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("failed"))
    exit(1)
}
