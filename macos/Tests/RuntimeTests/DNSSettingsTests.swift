import Foundation
import Testing
@testable import macos

struct DNSSettingsTests {
    @Test func systemIsTheDefaultAndExplicitlyClearsCustomDNS() throws {
        let defaults = try DNSConfiguration(settings: nil)
        #expect(defaults.mode == .system)
        #expect(defaults.customServer == "1.1.1.1")
        #expect(defaults.server == nil)
        #expect(defaults.updateArguments == ["--system-dns"])
        let retained = try DNSConfiguration(settings: ["dns_mode": "system", "dns_custom_server": "10.1.2.3"])
        #expect(retained.server == nil)
        #expect(retained.customServer == "10.1.2.3")
    }

    @Test func customServersAreValidatedWithoutSwitchingToSystemOnFailure() throws {
        let custom = try DNSConfiguration(settings: ["dns_mode": "custom", "dns_custom_server": " 10.1.2.3 \n"])
        #expect(custom.server == "10.1.2.3")
        #expect(custom.updateArguments == ["--dns", "10.1.2.3"])
        for value in ["", "dns.example.com", "1.1.1.1:53", "1.1.1.999", "::1", "0.0.0.0", "255.255.255.255"] {
            #expect(throws: ContainerBuildTools.Failure.self) {
                try DNSConfiguration(settings: ["dns_mode": "custom", "dns_custom_server": value])
            }
        }
        #expect(throws: ContainerBuildTools.Failure.self) { try DNSConfiguration(settings: ["dns_mode": "invalid"]) }
    }

    @Test func chromeUsesSystemDNSAndPreservesUnrelatedLocalState() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/dns-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Local State")
        try Data(#"{"profile":{"last_active_profiles":["Default"]},"async_dns":{"enabled":true,"other":7},"dns_over_https":{"mode":"secure","templates":"https://dns.example/dns-query"}}"#.utf8).write(to: url)
        try ChromeDNS.prepare(profileURL: root)
        try ChromeDNS.prepare(profileURL: root)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((saved["async_dns"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((saved["async_dns"] as? [String: Any])?["other"] as? Int == 7)
        #expect((saved["dns_over_https"] as? [String: String])?["mode"] == "off")
        #expect((saved["profile"] as? [String: [String]])?["last_active_profiles"] == ["Default"])
        try Data("not JSON".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ChromeDNS.prepare(profileURL: root) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not JSON")
    }
}
