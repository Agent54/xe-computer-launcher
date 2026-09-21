import Foundation
import Testing
@testable import macos

struct ComponentVersionsTests {
    @Test func readsEveryPackagedComponentVersion() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xe-component-versions-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("Contents/Resources")
        let helium = root.appendingPathComponent("Helium.app")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: resources.appendingPathComponent("SmolRuntime"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("Contents/Frameworks/Sparkle.framework/Versions/B/Resources"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: helium.appendingPathComponent("Contents"),
            withIntermediateDirectories: true
        )

        try Data(#"{"darc":{"version":{"major":1,"minor":2,"patch":3}}}"#.utf8)
            .write(to: resources.appendingPathComponent("sources.json"))
        try Data("SMOLVM_VERSION=1.16.2\nSMOLVM_RELEASE_TAG=v1.16.2-compose_3\n".utf8)
            .write(to: resources.appendingPathComponent("SmolRuntime/SmolVM.lock"))
        try Data("COMPOSE_SERVER_RELEASE_TAG=v5.1.3-int.2\n".utf8)
            .write(to: resources.appendingPathComponent("ComposeServer.lock"))
        try Data("COMPOSE_UI_RELEASE_TAG=int-8-637b350\n".utf8)
            .write(to: resources.appendingPathComponent("ComposeUI.lock"))
        try Data(#"{"dependencies":{"workerd":"1.20260910.1"}}"#.utf8)
            .write(to: resources.appendingPathComponent("Workerd.package.json"))
        try writePlist(
            version: "2.9.4",
            to: root.appendingPathComponent(
                "Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
            )
        )
        try writePlist(version: "0.9.4.1", to: helium.appendingPathComponent("Contents/Info.plist"))

        let versions = ComponentVersions.bundled(
            resourceURL: resources,
            contentsURL: root.appendingPathComponent("Contents"),
            heliumAppURL: helium
        )

        #expect(versions == [
            ComponentVersion(name: "Xe Computer", version: "1.2.3"),
            ComponentVersion(name: "Helium", version: "0.9.4.1"),
            ComponentVersion(name: "SmolVM", version: "v1.16.2-compose_3"),
            ComponentVersion(name: "Compose Server", version: "v5.1.3-int.2"),
            ComponentVersion(name: "Compose UI", version: "int-8-637b350"),
            ComponentVersion(name: "workerd", version: "1.20260910.1"),
            ComponentVersion(name: "Sparkle", version: "2.9.4")
        ])
        #expect(ComponentVersions.aboutText(for: versions).contains("Compose UI: int-8-637b350"))
    }

    @Test func reportsMissingMetadataWithoutOmittingComponents() {
        let versions = ComponentVersions.bundled(
            resourceURL: nil,
            contentsURL: nil,
            heliumAppURL: nil
        )

        #expect(versions.count == 7)
        #expect(versions.first == ComponentVersion(name: "Xe Computer", version: "Unknown"))
        #expect(versions[1] == ComponentVersion(name: "Helium", version: "Not installed"))
        #expect(versions.dropFirst(2).allSatisfy { $0.version == "Unknown" })
    }

    private func writePlist(version: String, to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
