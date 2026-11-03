import Testing
@testable import macos

struct ComponentVersionsTests {
    @Test func reportsMissingMetadataWithoutOmittingComponents() {
        let versions = ComponentVersions.bundled(
            resourceURL: nil,
            contentsURL: nil,
            heliumAppURL: nil
        )

        #expect(versions.count == 8)
        #expect(versions.first == ComponentVersion(name: "Xe Computer", version: "Unknown"))
        #expect(versions[1] == ComponentVersion(
            name: "Xe Computer active bundle",
            version: "Not activated by launcher"
        ))
        #expect(versions[2] == ComponentVersion(name: "Helium", version: "Not installed"))
        #expect(versions.dropFirst(3).allSatisfy { $0.version == "Unknown" })
    }
}
