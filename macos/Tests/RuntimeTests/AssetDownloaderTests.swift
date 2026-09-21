import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct AssetDownloaderTests {
    @Test func heliumVersionDeterminesWhetherUpgradeIsRequired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Helium.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = ["CFBundleShortVersionString": "0.9.4.1"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        #expect(heliumBundleVersion(at: app) == "0.9.4.1")
        #expect(heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1"))
        #expect(!heliumRequiresInstallation(at: app, requiredVersion: "0.9.4.1"))

        let newerPlist: [String: Any] = ["CFBundleShortVersionString": "0.18.0.0"]
        let newerData = try PropertyListSerialization.data(
            fromPropertyList: newerPlist,
            format: .xml,
            options: 0
        )
        try newerData.write(to: contents.appendingPathComponent("Info.plist"))
        #expect(!heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1"))
    }

    @Test func resolvesNewestVersionedEngineAndFallsBackSafely() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("Helium.app")
        let previous = heliumVersionedAppURL(dataURL: root, version: "0.16.6.1")
        let pinned = heliumVersionedAppURL(dataURL: root, version: "0.17.2.1")
        try writeHeliumApp(at: legacy, version: "0.9.4.1")
        try writeHeliumApp(at: previous, version: "0.16.6.1")
        try writeHeliumApp(at: pinned, version: "0.17.2.1")

        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1"
        )) == canonical(pinned))

        try FileManager.default.removeItem(at: pinned.deletingLastPathComponent())
        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1"
        )) == canonical(previous))

        let newer = heliumVersionedAppURL(dataURL: root, version: "0.18.0.0")
        try writeHeliumApp(at: newer, version: "0.18.0.0")
        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1"
        )) == canonical(newer))
    }

    @Test func sha256IsCalculatedWithoutLoadingTheWholeAsset() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        try Data("Xe Computer\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try sha256Hex(of: file) == "da95635aa047927ccd16950021226df995bc38236c5a3db9675713af6276152c")
    }

    private func writeHeliumApp(at appURL: URL, version: String) throws {
        let contents = appURL.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Helium")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = ["CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("test".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
    }

    private func canonical(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
