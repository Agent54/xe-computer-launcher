import Darwin
import Testing
@testable import macos

@Suite(.serialized)
struct WorkerdPortsTests {
    @Test func settingsUseDefaultsAndValidateOverrides() {
        let defaults = WorkerdPorts(settings: nil)
        #expect(defaults.http == 5196)
        #expect(defaults.https == 5194)
        #expect(defaults.settingWarnings.isEmpty)

        let standard = WorkerdPorts(settings: ["app_http_port": 80, "app_https_port": 443])
        #expect(standard.http == 80)
        #expect(standard.https == 443)
        #expect(standard.settingWarnings.isEmpty)

        let custom = WorkerdPorts(settings: ["app_http_port": 8080, "app_https_port": "8443"])
        #expect(custom.http == 8080)
        #expect(custom.https == 8443)
        #expect(custom.settingWarnings.isEmpty)

        for mixed in [["app_http_port": 80, "app_https_port": 8443],
                      ["app_http_port": 8080, "app_https_port": 443]] {
            let ports = WorkerdPorts(settings: mixed)
            #expect(ports.http == 5196)
            #expect(ports.https == 5194)
            #expect(ports.settingWarnings.contains { $0.contains("standard 80/443 pair") })
        }

        let invalid = WorkerdPorts(settings: ["app_http_port": true, "app_https_port": 70000])
        #expect(invalid.http == 5196)
        #expect(invalid.https == 5194)
        #expect(invalid.settingWarnings.count == 2)

        let fractional = WorkerdPorts(settings: ["app_http_port": 8080.5])
        #expect(fractional.http == 5196)
        #expect(fractional.settingWarnings.count == 1)

        let duplicate = WorkerdPorts(settings: ["app_http_port": 5194])
        #expect(duplicate.http == 5196)
        #expect(duplicate.https == 5194)
        #expect(!duplicate.settingWarnings.isEmpty)

        let management = WorkerdPorts(settings: ["app_https_port": 8094])
        #expect(management.http == 5196)
        #expect(management.https == 5194)
        #expect(!management.settingWarnings.isEmpty)

        let otherLowPorts = WorkerdPorts(settings: ["app_http_port": 81, "app_https_port": 444])
        #expect(otherLowPorts.http == 5196)
        #expect(otherLowPorts.https == 5194)
        #expect(otherLowPorts.settingWarnings.count == 2)
    }

    @Test func startupProbeReportsOccupiedLoopbackPort() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        guard bound == 0 else { return }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        #expect(named == 0)
        guard named == 0 else { return }
        let port = address.sin_port.bigEndian
        let configured = WorkerdPorts(settings: ["app_http_port": Int(port)])
        #expect(configured.bindingWarnings().contains("HTTP port \(port) is already in use."))
        #expect(!WorkerdPorts.portAvailable(port))
    }
}
