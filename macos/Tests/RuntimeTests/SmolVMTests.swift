import Testing
@testable import macos

@Suite
struct SmolVMTests {
    @Test func legacyRouterMigrationArgumentsKeepTheMachineAndAddResources() {
        let arguments = SmolVMClient.updateArguments(
            name: "xe-launcher",
            volumes: ["/host/guest-worker:/opt/xe/guest-worker:ro"],
            ports: ["5197:5197"]
        )

        #expect(arguments == [
            "machine", "update", "--name", "xe-launcher",
            "--volume", "/host/guest-worker:/opt/xe/guest-worker:ro",
            "--port", "5197:5197",
        ])
    }
}
