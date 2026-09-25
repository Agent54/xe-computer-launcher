import Foundation
import Testing
@testable import macos

struct LocalTLSCertificateTests {
    @Test func generatesAndReusesPrivateCertificate() throws {
        let root = URL(fileURLWithPath: "/tmp/xe-ui-https-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try LocalTLSCertificate.prepare(stateURL: root)
        #expect(prepared.createdCertificate)
        #expect(!LocalHTTPSTrust.isTrusted(certificateURL: prepared.certificateURL))
        #expect(String(decoding: try Data(contentsOf: prepared.certificateURL), as: UTF8.self)
            .contains("BEGIN CERTIFICATE"))
        let leaf = root.appendingPathComponent("ui-https/ui.crt")
        let leafData = try Data(contentsOf: leaf)
        let key = root.appendingPathComponent("ui-https/ui.key")
        let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let reused = try LocalTLSCertificate.prepare(stateURL: root)
        #expect(!reused.createdCertificate)
        #expect(try Data(contentsOf: reused.certificateURL) == Data(contentsOf: prepared.certificateURL))
        #expect(try Data(contentsOf: leaf) == leafData)
    }
}
