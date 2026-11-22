import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct SmolVMClientTests {
    @Test func cancellationObservesExitedProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let observer = ProcessExitObserver()
        observer.install(on: process)
        try process.run()
        let command = Task {
            await withTaskCancellationHandler {
                await observer.wait()
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            try Task.checkCancellation()
        }

        try await Task.sleep(for: .milliseconds(100))
        command.cancel()
        await #expect(throws: CancellationError.self) {
            try await command.value
        }
        #expect(!process.isRunning)
    }
}
