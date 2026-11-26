import AppKit
import Darwin
import Foundation

struct DNSConfiguration: Equatable, Sendable {
    enum Mode: String, Sendable { case system, custom }
    static let modeKey = "dns_mode"
    static let serverKey = "dns_custom_server"
    static let defaultCustomServer = "1.1.1.1"

    let mode: Mode
    let customServer: String

    init(settings: [String: Any]?) throws {
        let rawMode = settings?[Self.modeKey]
        if rawMode == nil { mode = .system }
        else if let text = rawMode as? String, let parsed = Mode(rawValue: text) { mode = parsed }
        else { throw ContainerBuildTools.Failure("Invalid DNS mode in launcher settings. Choose System or Custom DNS from the menu.") }
        if let server = settings?[Self.serverKey] {
            guard let text = server as? String else { throw ContainerBuildTools.Failure("The custom DNS server must be an IPv4 address.") }
            customServer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { customServer = Self.defaultCustomServer }
        if mode == .custom, !Self.isValidServer(customServer) {
            throw ContainerBuildTools.Failure("Invalid custom DNS server. Enter an IPv4 address, such as 1.1.1.1.")
        }
    }

    static func isValidServer(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) } == 1
            && address.s_addr != INADDR_ANY && address.s_addr != INADDR_BROADCAST
    }

    var server: String? { mode == .custom ? customServer : nil }
    var updateArguments: [String] { server.map { ["--dns", $0] } ?? ["--system-dns"] }
}

@MainActor
enum DNSSettings {
    static func change(to mode: DNSConfiguration.Mode) -> Bool {
        let state = ExternalState.shared
        let raw = state.settings.rawData
        let input = NSTextField(string: raw?[DNSConfiguration.serverKey] as? String ?? DNSConfiguration.defaultCustomServer)
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        input.setAccessibilityLabel("Custom DNS server IPv4 address")
        while true {
            if mode == .custom {
                let alert = NSAlert()
                alert.messageText = "Custom DNS"
                alert.informativeText = "Enter an IPv4 DNS server for the container VM, Docker containers, and builds. Chrome uses system DNS; it has no supported custom DNS-IP option.\n\nSaving applies after restarting Xe Launcher and interrupts containers when you restart."
                alert.accessoryView = input
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = input
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
            var updated = raw ?? [:]
            updated[DNSConfiguration.modeKey] = mode.rawValue
            updated[DNSConfiguration.serverKey] = input.stringValue
            do {
                let configuration = try DNSConfiguration(settings: updated)
                if configuration == (try? DNSConfiguration(settings: raw)) { return false }
                try state.setDNSConfiguration(configuration)
                return true
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "DNS Settings Could Not Be Saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                if mode == .system { return false }
            }
        }
    }
}

enum ChromeDNS {
    /// Chromium's Local State preferences select the OS resolver and disable
    /// Secure DNS upgrades. Merge while stopped, including on provisioning's
    /// second launch after it replaces Local State with the bundled template.
    static func prepare(profileURL: URL) throws {
        let url = profileURL.appendingPathComponent("Local State")
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw ContainerBuildTools.Failure("Chrome Local State is not a JSON object; system DNS could not be configured.")
            }
            settings = object
        }
        for key in ["async_dns", "dns_over_https"] {
            if let value = settings[key], !(value is [String: Any]) {
                throw ContainerBuildTools.Failure("Chrome's \(key) preferences are invalid; system DNS could not be configured.")
            }
        }
        var asynchronous = settings["async_dns"] as? [String: Any] ?? [:]
        var secure = settings["dns_over_https"] as? [String: Any] ?? [:]
        asynchronous["enabled"] = false
        secure["mode"] = "off"
        settings["async_dns"] = asynchronous
        settings["dns_over_https"] = secure
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
