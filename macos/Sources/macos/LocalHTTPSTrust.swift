import Foundation
import Security

enum LocalHTTPSTrustError: LocalizedError {
    case certificateUnavailable
    case keychainUnavailable
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable:
            "The local HTTPS certificate is unavailable."
        case .keychainUnavailable:
            "macOS did not identify the current user's default Keychain."
        case .installationFailed(let detail):
            "macOS did not install the local HTTPS certificate: \(detail)"
        }
    }
}

/// Checks the same macOS user trust that Chromium reads for local TLS roots.
/// Never supplies a custom anchor: doing so would make an untrusted CA pass.
enum LocalHTTPSTrust {
    static func isTrusted(certificateURL: URL) -> Bool {
        let leafURL = certificateURL.deletingLastPathComponent().appendingPathComponent("ui.crt")
        guard loadCertificate(at: certificateURL) != nil,
              let leaf = loadCertificate(at: leafURL) else {
            return false
        }

        let policy = SecPolicyCreateSSL(true, "compose-ui.localhost" as CFString)
        var trust: SecTrust?
        // Supplying the self-signed root in this chain can make macOS accept
        // it even when no Keychain trusts it. Browser verification starts with
        // the leaf and must discover the installed root on its own.
        guard SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// OpenSSL writes our certificates in PEM format, while Security.framework
    /// requires DER bytes when creating a SecCertificate.
    static func loadCertificate(at url: URL) -> SecCertificate? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            return certificate
        }
        guard let text = String(data: data, encoding: .utf8),
              let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex),
              let der = Data(base64Encoded: String(text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace })) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    /// Apple's security tool adds the CA to the current user's default Keychain
    /// and invokes macOS authentication for the per-user SSL trust setting.
    static func requestUserTrust(certificateURL: URL) throws {
        guard FileManager.default.fileExists(atPath: certificateURL.path) else {
            throw LocalHTTPSTrustError.certificateUnavailable
        }
        let keychainResult = try ProcessCapture.standardOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["default-keychain", "-d", "user"]
        )
        let keychainPath = String(decoding: keychainResult.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard keychainResult.exitCode == 0, keychainPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: keychainPath) else {
            throw LocalHTTPSTrustError.keychainUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
                             "-k", keychainPath, certificateURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalHTTPSTrustError.installationFailed(
                detail.isEmpty ? "security exited \(process.terminationStatus)" : detail)
        }
    }
}
