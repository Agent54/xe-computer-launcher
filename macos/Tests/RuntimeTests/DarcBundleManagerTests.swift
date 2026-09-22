import Foundation
import Testing
@testable import macos

@Suite(.serialized)
struct DarcBundleManagerTests {
    @Test func replacesMatchingProfileBundleAndDerivesEffectiveVersion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("darc.0.0.20.swbn")
        let installed = root.appendingPathComponent(
            "profiles/default/Default/iwa/installed/main.swbn"
        )
        try writeFakeBundle(version: "0.0.20", to: source)
        try writeFakeBundle(version: "0.0.18", payload: "old", to: installed)

        let summary = try activateDarcBundle(
            sourceURL: source,
            expectedVersion: "0.0.20",
            dataURL: root
        )

        #expect(summary.activatedProfiles == ["default"])
        #expect(summary.verifiedProfiles.isEmpty)
        #expect(summary.failedProfiles.isEmpty)
        #expect(try Data(contentsOf: installed) == Data(contentsOf: source))

        let sourceHash = try sha256Hex(of: source)
        #expect(activeDarcBundleActivation(
            dataURL: root,
            profileName: "default",
            sourceURL: source,
            expectedVersion: "0.0.20"
        ) ==
            DarcProfileBundleActivation(
                profileName: "default",
                version: "0.0.20",
                sha256: sourceHash,
                webBundleID: trustedXeComputerWebBundleID,
                relativeBundlePath: "profiles/default/Default/iwa/installed/main.swbn"
            ))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("darc-profile-state.json").path
        ))

        let secondSummary = try activateDarcBundle(
            sourceURL: source,
            expectedVersion: "0.0.20",
            dataURL: root
        )
        #expect(secondSummary.activatedProfiles.isEmpty)
        #expect(secondSummary.verifiedProfiles == ["default"])
    }

    @Test func neverReplacesAnotherIsolatedWebApp() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("darc.0.0.20.swbn")
        let installed = root.appendingPathComponent(
            "profiles/default/Default/iwa/another-app/main.swbn"
        )
        try writeFakeBundle(version: "0.0.20", to: source)
        try writeFakeBundle(
            version: "9.9.9",
            webBundleID: String(repeating: "a", count: 56),
            payload: "unrelated",
            to: installed
        )
        let original = try Data(contentsOf: installed)

        let summary = try activateDarcBundle(
            sourceURL: source,
            expectedVersion: "0.0.20",
            dataURL: root
        )

        #expect(summary == DarcBundleActivationSummary())
        #expect(try Data(contentsOf: installed) == original)
        #expect(activeDarcBundleActivation(
            dataURL: root,
            profileName: "default",
            sourceURL: source,
            expectedVersion: "0.0.20"
        ) == nil)
    }

    @Test func updatesEveryMatchingBundleAmongMultipleInstalledIWAs() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("darc.0.0.20.swbn")
        let first = root.appendingPathComponent(
            "profiles/default/Default/iwa/first/main.swbn"
        )
        let second = root.appendingPathComponent(
            "profiles/default/Default/iwa/second/main.swbn"
        )
        let unrelated = root.appendingPathComponent(
            "profiles/default/Default/iwa/unrelated/main.swbn"
        )
        try writeFakeBundle(version: "0.0.20", to: source)
        try writeFakeBundle(version: "0.0.18", payload: "first", to: first)
        try writeFakeBundle(version: "0.0.19", payload: "second", to: second)
        try writeFakeBundle(
            version: "9.9.9",
            webBundleID: String(repeating: "a", count: 56),
            payload: "unrelated",
            to: unrelated
        )
        let originalUnrelated = try Data(contentsOf: unrelated)

        let summary = try activateDarcBundle(
            sourceURL: source,
            expectedVersion: "0.0.20",
            dataURL: root
        )

        #expect(summary.failedProfiles.isEmpty)
        #expect(summary.activatedProfiles == ["default"])
        #expect(try Data(contentsOf: first) == Data(contentsOf: source))
        #expect(try Data(contentsOf: second) == Data(contentsOf: source))
        #expect(try Data(contentsOf: unrelated) == originalUnrelated)
    }

    @Test func rejectsBundleWhoseManifestVersionDoesNotMatchThePin() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("darc.0.0.20.swbn")
        try writeFakeBundle(
            version: "0.0.19",
            payload: #"const dependency = {"version":"0.0.20"};"#,
            to: source
        )

        do {
            _ = try activateDarcBundle(
                sourceURL: source,
                expectedVersion: "0.0.20",
                dataURL: root
            )
            Issue.record("Expected mismatched Darc manifest version to be rejected")
        } catch let error as DarcBundleActivationError {
            #expect(error.localizedDescription.contains("manifest version 0.0.20"))
        }
    }

    @Test func diagnosticsAreDerivedFromTheCurrentProfileBundle() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("darc.0.0.20.swbn")
        let installed = root.appendingPathComponent(
            "profiles/default/Default/iwa/installed/main.swbn"
        )
        try writeFakeBundle(version: "0.0.20", to: source)
        try writeFakeBundle(version: "0.0.18", to: installed)
        _ = try activateDarcBundle(
            sourceURL: source,
            expectedVersion: "0.0.20",
            dataURL: root
        )
        #expect(activeDarcBundleActivation(
            dataURL: root,
            profileName: "default",
            sourceURL: source,
            expectedVersion: "0.0.20"
        ) != nil)
        try Data("externally changed".utf8).write(to: installed, options: .atomic)

        #expect(activeDarcBundleActivation(
            dataURL: root,
            profileName: "default",
            sourceURL: source,
            expectedVersion: "0.0.20"
        ) == nil)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarcBundleManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFakeBundle(
        version: String,
        webBundleID: String = trustedXeComputerWebBundleID,
        payload: String = "new",
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = """
        signed-web-bundle-test-data
        isolated-app://\(webBundleID)/.well-known/manifest.webmanifest
        { "name": "Xe Computer", "version" : "\(version)" }
        \(payload)
        \(String(repeating: "x", count: 2_000))
        """
        try Data(contents.utf8).write(to: url)
    }
}
