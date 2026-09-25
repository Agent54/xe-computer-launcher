import Foundation
import Security

enum LocalHTTPSTrustError: LocalizedError {
    case certificateUnavailable
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .certificateUnavailable:
            "The local HTTPS certificate is unavailable."
        case .installationFailed:
            "macOS did not install the local HTTPS certificate."
        }
    }
}

/// Checks the same macOS user trust that Chromium reads for local TLS roots.
/// Never supplies a custom anchor: doing so would make an untrusted CA pass.
enum LocalHTTPSTrust {
    static func isTrusted(certificateURL: URL) -> Bool {
        let leafURL = certificateURL.deletingLastPathComponent().appendingPathComponent("ui.crt")
        guard let rootData = try? Data(contentsOf: certificateURL),
              let leafData = try? Data(contentsOf: leafURL),
              let root = SecCertificateCreateWithData(nil, rootData as CFData),
              let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
            return false
        }

        let policy = SecPolicyCreateSSL(true, "compose-ui.localhost" as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, root] as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Apple's security tool adds the CA to the current user's default Keychain
    /// and invokes macOS authentication for the per-user SSL trust setting.
    static func requestUserTrust(certificateURL: URL) throws {
        guard FileManager.default.fileExists(atPath: certificateURL.path) else {
            throw LocalHTTPSTrustError.certificateUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", certificateURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw LocalHTTPSTrustError.installationFailed
        }
    }
}
