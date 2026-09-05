import Foundation

enum UnixSocketHTTP {
    /// curl ships with macOS and supports HTTP over Unix sockets. Run the
    /// bounded probe off the main actor so VM boot never blocks the menu bar.
    static func isReady(at socketURL: URL, path: String = "/_ping") async -> Bool {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return false }
        return await Task.detached {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            probe.arguments = [
                "--disable", "--silent", "--fail", "--max-time", "1",
                "--noproxy", "*", "--unix-socket", socketURL.path,
                "--output", "/dev/null", "http://localhost\(path)",
            ]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            probe.standardInput = FileHandle.nullDevice
            do {
                try probe.run()
                probe.waitUntilExit()
                return probe.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
