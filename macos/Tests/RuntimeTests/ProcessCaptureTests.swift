import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct ProcessCaptureTests {
    @Test func drainsOutputLargerThanPipeCapacity() throws {
        let result = try ProcessCapture.standardOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/jot"),
            arguments: ["50000"]
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count > 64 * 1024)
        let output = try #require(String(data: result.standardOutput, encoding: .utf8))
        #expect(output.hasSuffix("50000\n"))
    }
}
