import Foundation

struct ProcessCaptureResult: Sendable {
    let standardOutput: Data
    let exitCode: Int32
}

enum ProcessCapture {
    static func standardOutput(
        executableURL: URL,
        arguments: [String]
    ) throws -> ProcessCaptureResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Drain while the child is running. Waiting first can deadlock when the
        // child fills the pipe buffer (for example, `ps` on a busy system).
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessCaptureResult(
            standardOutput: data,
            exitCode: process.terminationStatus
        )
    }
}
