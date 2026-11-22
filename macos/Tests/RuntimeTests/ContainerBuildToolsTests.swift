import Foundation
import Testing
@testable import macos

struct ContainerBuildToolsTests {
    private var macosURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func managedClientKeepsCredentialsAndProxiesWithoutInheritingRemoteContext() throws {
        let source = Data(#"{"auths":{"registry.example":{"auth":"fixture"}},"credsStore":"osxkeychain","proxies":{"default":{"httpProxy":"http://proxy"}},"currentContext":"remote","cliPluginsExtraDirs":["/old"]}"#.utf8)
        let output = try ContainerBuildTools.configuration(source, pluginDirectory: URL(fileURLWithPath: "/bundle/cli-plugins"))
        let config = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(config["currentContext"] == nil)
        #expect(config["cliPluginsExtraDirs"] as? [String] == ["/bundle/cli-plugins"])
        #expect(config["credsStore"] as? String == "osxkeychain")
        #expect(config["auths"] as? [String: [String: String]] == ["registry.example": ["auth": "fixture"]])
        #expect(config["proxies"] as? [String: [String: String]] == ["default": ["httpProxy": "http://proxy"]])
    }

    @Test func missingBuildxFailsInsteadOfStartingClassicBuilds() async throws {
        await #expect(throws: ContainerBuildTools.Failure.self) {
            try await ContainerBuildTools.prepareHost(
                pluginURL: macosURL.appendingPathComponent("missing-buildx"),
                dockerSocketURL: URL(fileURLWithPath: "/missing.sock")
            )
        }
    }

    @Test func realBundledBuildxPreparesOfflineAndCanBePreparedAgain() async throws {
        let root = macosURL.appendingPathComponent(".build/build-tools-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = macosURL.appendingPathComponent(".build/container-tools")
        let plugin = tools.appendingPathComponent("Resources/ContainerTools/cli-plugins/docker-buildx")
        try #require(FileManager.default.isExecutableFile(atPath: plugin.path), "Run make container-tools first")
        for _ in 0..<2 {
            let environment = try await ContainerBuildTools.prepareHost(
                pluginURL: plugin, resourceURL: tools.appendingPathComponent("Resources/ContainerTools"), clientURL: root,
                sourceConfigURL: root.appendingPathComponent("absent.json"),
                dockerSocketURL: URL(fileURLWithPath: "/missing-xe-test.sock")
            )
            #expect(environment["DOCKER_BUILDKIT"] == "1")
            #expect(environment["BUILDX_BUILDER"] == "xe")
            #expect(environment["DOCKER_HOST"] == "unix:///missing-xe-test.sock")
            #expect(environment["XE_SMOLVM_DATA_DIR"] == RuntimeSocketPaths.shared.smolDataURL.path)
            let config = try Data(contentsOf: root.appendingPathComponent("config.json"))
            let parsed = try #require(JSONSerialization.jsonObject(with: config) as? [String: Any])
            #expect(parsed["cliPluginsExtraDirs"] as? [String] == [plugin.deletingLastPathComponent().path])
        }
    }
}
