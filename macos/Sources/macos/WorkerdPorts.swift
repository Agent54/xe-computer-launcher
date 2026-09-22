import Foundation
import CoreFoundation
import Darwin

struct WorkerdPorts {
    static let defaultHTTP: UInt16 = 80
    static let defaultHTTPS: UInt16 = 443
    static let management: UInt16 = 8094

    let http: UInt16
    let https: UInt16
    let settingWarnings: [String]

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
            return UInt16(value)
        }

        var http = configuredPort("app_http_port", fallback: Self.defaultHTTP)
        var https = configuredPort("app_https_port", fallback: Self.defaultHTTPS)
        if http == https || http == Self.management || https == Self.management {
            warnings.append("App HTTP and HTTPS ports must be distinct and cannot use management port \(Self.management); using ports 80 and 443.")
            http = Self.defaultHTTP
            https = Self.defaultHTTPS
        }
        self.http = http
        self.https = https
        settingWarnings = warnings
    }

    /// Probe the exact loopback addresses workerd will bind. This is only a
    /// startup warning; workerd's own bind remains the source of truth.
    func bindingWarnings() -> [String] {
        [("HTTP", http), ("HTTPS", https)].compactMap { label, port in
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
}
