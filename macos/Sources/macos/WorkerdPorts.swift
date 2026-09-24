import Foundation
import CoreFoundation
import Darwin

struct WorkerdPorts {
    static let defaultHTTP: UInt16 = 5196
    static let defaultHTTPS: UInt16 = 5194
    static let standardHTTP: UInt16 = 80
    static let standardHTTPS: UInt16 = 443
    static let management: UInt16 = 8094

    let http: UInt16
    let https: UInt16
    let settingWarnings: [String]

    static func hasExplicitPortSetting(_ settings: [String: Any]?) -> Bool {
        ["app_http_port", "app_https_port"].contains { key in
            guard let value = settings?[key] else { return false }
            return !(value is NSNull)
        }
    }

    static func needsPortChoice(_ settings: [String: Any]?) -> Bool {
        guard hasExplicitPortSetting(settings) else { return true }
        guard settings?["app_port_choice_confirmed"] as? Bool != true else { return false }
        let ports = WorkerdPorts(settings: settings)
        // Older setup saved these defaults without an explicit port decision.
        // Keep standard and manually configured non-default pairs unchanged.
        return ports.http == defaultHTTP && ports.https == defaultHTTPS && ports.settingWarnings.isEmpty
    }

    init(settings: [String: Any]?) {
        var warnings: [String] = []

        func configuredPort(_ key: String, fallback: UInt16) -> UInt16 {
            guard let raw = settings?[key] else { return fallback }
            let value: Int?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
               (1.0...65535.0).contains(number.doubleValue) {
                value = number.intValue
            } else if let string = raw as? String {
                value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                value = nil
            }
            guard let value, (1...65535).contains(value) else {
                warnings.append("Invalid \(key) setting; using port \(fallback).")
                return fallback
            }
            let standard = key == "app_http_port" ? Self.standardHTTP : Self.standardHTTPS
            if value < 1024 && value != standard {
                warnings.append("Custom privileged \(key) port \(value) is unsupported; using port \(fallback).")
                return fallback
            }
            return UInt16(value)
        }

        var http = configuredPort("app_http_port", fallback: Self.defaultHTTP)
        var https = configuredPort("app_https_port", fallback: Self.defaultHTTPS)
        if (http == Self.standardHTTP) != (https == Self.standardHTTPS) {
            warnings.append("App ports must use either the standard 80/443 pair or two custom ports; using ports \(Self.defaultHTTP) and \(Self.defaultHTTPS).")
            http = Self.defaultHTTP
            https = Self.defaultHTTPS
        } else if http == https || http == Self.management || https == Self.management {
            warnings.append("App HTTP and HTTPS ports must be distinct and cannot use management port \(Self.management); using ports \(Self.defaultHTTP) and \(Self.defaultHTTPS).")
            http = Self.defaultHTTP
            https = Self.defaultHTTPS
        }
        self.http = http
        self.https = https
        settingWarnings = warnings
    }

    /// Probe the exact loopback addresses workerd will bind. This is only a
    /// startup warning; workerd's own bind remains the source of truth.
    func bindingWarnings(skipStandardPorts: Bool = false) -> [String] {
        [("HTTP", http), ("HTTPS", https)].compactMap { label, port in
            if skipStandardPorts && (port == Self.standardHTTP || port == Self.standardHTTPS) { return nil }
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else {
                return "\(label) port \(port) could not be checked: \(String(cString: strerror(errno)))."
            }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result != 0 else { return nil }
            let reason = errno
            if reason == EADDRINUSE { return "\(label) port \(port) is already in use." }
            return "\(label) port \(port) cannot be bound: \(String(cString: strerror(reason)))."
        }
    }

    /// A privileged bind may fail with EPERM even when the port is free. In
    /// that case a refused loopback connection confirms there is no listener;
    /// the launchd helper will perform the privileged bind after approval.
    static func standardPortsAvailable() -> Bool {
        [standardHTTP, standardHTTPS].allSatisfy(portAvailable)
    }

    static func portAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound == 0 { return true }
        guard errno == EACCES || errno == EPERM else { return false }
        let connection = socket(AF_INET, SOCK_STREAM, 0)
        guard connection >= 0 else { return false }
        defer { close(connection) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && errno == ECONNREFUSED
    }
}
