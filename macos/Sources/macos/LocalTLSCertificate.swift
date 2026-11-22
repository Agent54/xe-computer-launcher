import Foundation

enum LocalTLSCertificateError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): "Local TLS certificate setup failed: \(message)"
        }
    }
}

/// Creates and reuses the per-user CA and HTTPS certificate. Workerd reads the
/// leaf keypair from its text configuration when it starts.
enum LocalTLSCertificate {
    struct Prepared: Sendable {
        let directoryURL: URL
        let certificateURL: URL
        let createdCertificate: Bool
    }

    static func prepare(stateURL: URL) throws -> Prepared {
        let directory = stateURL.appendingPathComponent("ui-https", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let certificateURL = directory.appendingPathComponent("root.crt")
        let rootKeyURL = directory.appendingPathComponent("root.key")
        let leafURL = directory.appendingPathComponent("ui.crt")
        let keyURL = directory.appendingPathComponent("ui.key")
        let createdCertificate = !FileManager.default.fileExists(atPath: certificateURL.path) ||
            !FileManager.default.fileExists(atPath: rootKeyURL.path) ||
            (try? run("/usr/bin/openssl", arguments: ["x509", "-checkend", "2592000", "-noout",
                                                   "-in", certificateURL.path])) == nil
        if createdCertificate {
            let temporaryKey = directory.appendingPathComponent("root-\(UUID().uuidString).key")
            let temporaryCertificate = directory.appendingPathComponent("root-\(UUID().uuidString).crt")
            defer {
                try? FileManager.default.removeItem(at: temporaryKey)
                try? FileManager.default.removeItem(at: temporaryCertificate)
            }
            try run("/usr/bin/openssl", arguments: [
                "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
                "-keyout", temporaryKey.path, "-out", temporaryCertificate.path,
                "-subj", "/CN=Xe Computer Local Development CA",
                "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            ])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryKey.path)
            if FileManager.default.fileExists(atPath: rootKeyURL.path) { try FileManager.default.removeItem(at: rootKeyURL) }
            if FileManager.default.fileExists(atPath: certificateURL.path) { try FileManager.default.removeItem(at: certificateURL) }
            try FileManager.default.moveItem(at: temporaryKey, to: rootKeyURL)
            try FileManager.default.moveItem(at: temporaryCertificate, to: certificateURL)
        }
        let needsLeaf = createdCertificate || !FileManager.default.fileExists(atPath: leafURL.path) ||
            !FileManager.default.fileExists(atPath: keyURL.path) ||
            (try? run("/usr/bin/openssl", arguments: ["x509", "-checkend", "2592000", "-noout",
                                                   "-in", leafURL.path])) == nil ||
            (try? run("/usr/bin/openssl", arguments: ["verify", "-CAfile", certificateURL.path,
                                                   leafURL.path])) == nil ||
            !certificateHasDNSName(leafURL, "*.app.localhost")
        if needsLeaf {
            let temporaryKey = directory.appendingPathComponent("ui-\(UUID().uuidString).key")
            let requestURL = directory.appendingPathComponent("ui-\(UUID().uuidString).csr")
            let temporaryCertificate = directory.appendingPathComponent("ui-\(UUID().uuidString).crt")
            let extensionsURL = directory.appendingPathComponent("ui-\(UUID().uuidString).ext")
            defer {
                for url in [temporaryKey, requestURL, temporaryCertificate, extensionsURL] {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            try run("/usr/bin/openssl", arguments: [
                "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", temporaryKey.path,
                "-out", requestURL.path, "-subj", "/CN=compose-ui.localhost",
            ])
            let extensions = """
            [server]
            subjectAltName=DNS:compose-ui.localhost,DNS:*.app.localhost
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            """
            try Data(extensions.utf8).write(to: extensionsURL, options: .atomic)
            let serial = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            try run("/usr/bin/openssl", arguments: [
                "x509", "-req", "-in", requestURL.path, "-CA", certificateURL.path,
                "-CAkey", rootKeyURL.path, "-out", temporaryCertificate.path,
                "-days", "397", "-set_serial", "0x\(serial)", "-extfile", extensionsURL.path,
                "-extensions", "server",
            ])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryKey.path)
            if FileManager.default.fileExists(atPath: keyURL.path) { try FileManager.default.removeItem(at: keyURL) }
            if FileManager.default.fileExists(atPath: leafURL.path) { try FileManager.default.removeItem(at: leafURL) }
            try FileManager.default.moveItem(at: temporaryKey, to: keyURL)
            try FileManager.default.moveItem(at: temporaryCertificate, to: leafURL)
        }

        return Prepared(directoryURL: directory,
                        certificateURL: certificateURL,
                        createdCertificate: createdCertificate)
    }

    private static func run(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LocalTLSCertificateError.commandFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
    }

    private static func certificateHasDNSName(_ certificateURL: URL, _ name: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["x509", "-noout", "-text", "-in", certificateURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && String(decoding: data, as: UTF8.self).contains("DNS:\(name)")
    }
}
