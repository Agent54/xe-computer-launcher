import Foundation
import Network
import os
import ResumableDownloads
import Testing
@testable import macos

@Suite(.serialized)
struct AssetDownloaderTests {
    @Test func archivePruningProtectsRequestedAndLockedPartials() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let urls = (0..<3).map { URL(string: "https://example.test/\($0).dmg")! }
        let files = urls.map { root.appendingPathComponent(XEArchiveTransfer.partialFilename(for: $0)) }
        for file in files {
            try Data("saved bytes".utf8).write(to: file)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -11 * 86400)], ofItemAtPath: file.path)
        }
        let fd = open(files[1].path, O_RDWR | O_EXLOCK | O_NONBLOCK)
        try #require(fd >= 0)
        XEArchiveTransfer.prune(directory: root.path, retaining: urls[0])
        #expect(fm.fileExists(atPath: files[0].path))
        #expect(fm.fileExists(atPath: files[1].path))
        #expect(!fm.fileExists(atPath: files[2].path))
        close(fd)
        XEArchiveTransfer.prune(directory: root.path, retaining: urls[0])
        #expect(!fm.fileExists(atPath: files[1].path))
        #expect(try Data(contentsOf: files[0]) == Data("saved bytes".utf8))
    }

    @Test func reclaimsSupersededAndAbandonedSetupDownloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pinned = URL(string: "https://example.test/releases/2/engine.dmg")!
        let older = URL(string: "https://example.test/releases/1/engine.dmg")!
        let lease = try lockSourceDownloadCache(directory, operation: LOCK_SH)
        let current = directory.appendingPathComponent(XEArchiveTransfer.partialFilename(for: pinned))
        let superseded = directory.appendingPathComponent(XEArchiveTransfer.partialFilename(for: older))
        let staged = directory.appendingPathComponent(UUID().uuidString + ".dmg")
        let unrelated = directory.appendingPathComponent("notes")
        for file in [current, superseded, staged, unrelated] { try Data("keep".utf8).write(to: file) }

        try pruneSourceDownloadCache(directory, retaining: [])
        #expect(FileManager.default.fileExists(atPath: staged.path))
        try lease.close()
        try pruneSourceDownloadCache(directory, retaining: [pinned])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() ==
            [current.lastPathComponent, unrelated.lastPathComponent].sorted())
        try pruneSourceDownloadCache(directory, retaining: [])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [unrelated.lastPathComponent])
    }

    @Test func setupResumesACancelledSourceAsset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "AssetDownloaderTests.http")
        let prefix = String(repeating: "a", count: 32 * 1024)
        let length = prefix.utf8.count
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let requests = OSAllocatedUnfairLock(initialState: 0)
        listener.newConnectionHandler = { connection in
            let attempt = requests.withLock { $0 += 1; return $0 }
            connection.start(queue: queue)
            // Read through the blank line even if the request headers span packets.
            @Sendable func respond(_ accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, !data.isEmpty else { connection.cancel(); return }
                    let request = accumulated + data
                    let headers = String(decoding: request, as: UTF8.self).lowercased()
                    guard headers.contains("\r\n\r\n") else { respond(request); return }
                    let reply: String
                    if attempt == 1 {
                        reply = "200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(2 * length)\r\nETag: \"v1\"\r\n\r\n\(prefix)"
                    } else if headers.contains("\r\nrange: bytes=\(length)-\r\n") && headers.contains("\r\nif-range: \"v1\"\r\n") {
                        reply = "206 Partial Content\r\nContent-Range: bytes \(length)-\(2 * length - 1)/\(2 * length)\r\nContent-Length: \(length)\r\n\r\n" + String(repeating: "b", count: length)
                    } else {
                        reply = "400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                    }
                    connection.send(content: Data("HTTP/1.1 \(reply)".utf8), completion: .contentProcessed { _ in
                        if attempt != 1 { connection.cancel() }
                    })
                }
            }
            respond(Data())
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        try #require(ready.wait(timeout: .now() + 5) == .success)
        let port = try #require(listener.port)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/engine.dmg"))
        let token = CancellationToken()
        #expect(throws: (any Error).self) {
            try downloadSourceAsset(from: url, directory: directory, cancellation: token) { fraction in
                if fraction == 0.5 { token.cancel() }
            }
        }
        #expect(token.isCancelled)
        let file = try downloadSourceAsset(from: url, directory: directory, cancellation: CancellationToken()) { _ in }
        #expect(try Data(contentsOf: file) == Data((prefix + String(repeating: "b", count: length)).utf8))
        #expect(requests.withLock { $0 } == 2)
    }

    @Test(arguments: [false, true])
    func setupAllowsThreeResumeRetries(succeedsOnLastAttempt: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "AssetDownloaderTests.retries")
        let length = 32 * 1024
        let prefix = String(repeating: "a", count: length)
        let ready = DispatchSemaphore(value: 0)
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let active = OSAllocatedUnfairLock<NWConnection?>(initialState: nil)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            let attempt = requests.withLock { $0 += 1; return $0 }
            active.withLock { $0 = connection }
            connection.start(queue: queue)
            @Sendable func respond(_ accumulated: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                    guard let data, !data.isEmpty else { connection.cancel(); return }
                    let request = accumulated + data
                    let headers = String(decoding: request, as: UTF8.self).lowercased()
                    guard headers.contains("\r\n\r\n") else { respond(request); return }
                    let offset = (attempt - 1) * length
                    let status = attempt == 1 ? "200 OK" :
                        "206 Partial Content\r\nContent-Range: bytes \(offset)-\(5 * length - 1)/\(5 * length)"
                    if attempt > 1 {
                        #expect(headers.contains("\r\nrange: bytes=\(offset)-\r\n"))
                        #expect(headers.contains("\r\nif-range: \"v1\"\r\n"))
                    }
                    let body = succeedsOnLastAttempt && attempt == 4 ? prefix + prefix : prefix
                    let reply = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nETag: \"v1\"\r\nContent-Length: \(5 * length - offset)\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                }
            }
            respond(Data())
        }
        listener.start(queue: queue)
        defer {
            active.withLock { $0?.cancel() }
            listener.cancel()
        }
        try #require(ready.wait(timeout: .now() + 5) == .success)
        let port = try #require(listener.port)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/engine.dmg"))
        let download = {
            try downloadSourceAsset(from: url, directory: directory, cancellation: CancellationToken()) { fraction in
                let attempt = requests.withLock { $0 }
                if !(succeedsOnLastAttempt && attempt == 4), fraction == Double(attempt) / 5 {
                    active.withLock { $0?.cancel() }
                }
            }
        }
        if succeedsOnLastAttempt {
            let file = try download()
            #expect(try Data(contentsOf: file) == Data(String(repeating: prefix, count: 5).utf8))
        } else {
            #expect(throws: (any Error).self) { try download() }
            let partial = directory.appendingPathComponent(XEArchiveTransfer.partialFilename(for: url))
            #expect(try Data(contentsOf: partial).count == 4 * length)
        }
        #expect(requests.withLock { $0 } == 4)
    }

    @Test func heliumVersionDeterminesWhetherUpgradeIsRequired() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Helium.app")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHeliumApp(at: app, version: "0.9.4.1")

        #expect(heliumBundleVersion(at: app) == "0.9.4.1")
        #expect(heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1", verify: verifyFixture))
        #expect(!heliumRequiresInstallation(at: app, requiredVersion: "0.9.4.1", verify: verifyFixture))
        try FileManager.default.removeItem(at: app)
        try writeHeliumApp(at: app, version: "0.18.0.0")
        #expect(!heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1", verify: verifyFixture))
        #expect(heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1")) // Test key is not the publisher.
    }

    @Test func resolvesOnlyVerifiedEnginesThatSatisfyThePin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = root.appendingPathComponent("Helium.app")
        let previous = heliumVersionedAppURL(dataURL: root, version: "0.16.6.1")
        let pinned = heliumVersionedAppURL(dataURL: root, version: "0.17.2.1")
        try writeHeliumApp(at: legacy, version: "0.9.4.1")
        try writeHeliumApp(at: previous, version: "0.16.6.1")
        try writeHeliumApp(at: pinned, version: "0.17.2.1")

        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1", verify: verifyFixture
        )) == canonical(pinned))

        try FileManager.default.removeItem(at: pinned.deletingLastPathComponent())
        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1", verify: verifyFixture
        )) == nil)

        let newer = heliumVersionedAppURL(dataURL: root, version: "0.18.0.0")
        try writeHeliumApp(at: newer, version: "0.18.0.0")
        #expect(canonical(bestInstalledHeliumAppURL(
            dataURL: root,
            requiredVersion: "0.17.2.1", verify: verifyFixture
        )) == canonical(newer))
    }

    @Test(arguments: ["Resources/payload", "Frameworks/payload", "MacOS/Helium", "_CodeSignature/CodeResources"])
    func damagedHeliumDoesNotSuppressRepair(missing: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = heliumVersionedAppURL(dataURL: root, version: "0.17.2.1")
        try writeHeliumApp(at: app, version: "0.17.2.1")
        try verifyFixture(app)
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/" + missing))
        #expect(heliumRequiresInstallation(at: app, requiredVersion: "0.17.2.1", verify: verifyFixture))
        #expect(bestInstalledHeliumAppURL(dataURL: root, requiredVersion: "0.17.2.1", verify: verifyFixture) == nil)
    }

    @Test func newSetupAttemptDoesNotReuseCancelledToken() {
        let first = beginSetupAttempt()
        first.cancel()
        let second = beginSetupAttempt()
        #expect(first.isCancelled)
        #expect(!second.isCancelled)
        #expect(setupCancellation === second)
        first.cancel()
        #expect(!second.isCancelled)
    }

    @Test func discardsBackupsAndInvalidHeliumWithoutRestoringThem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let version = "0.17.2.1"
        let app = heliumVersionedAppURL(dataURL: root, version: version)
        let installed = app.deletingLastPathComponent()
        let backup = installed.deletingLastPathComponent().appendingPathComponent(".\(version).replaced-\(UUID().uuidString)")
        try writeHeliumApp(at: backup.appendingPathComponent("Helium.app"), version: version)
        let staged = root.appendingPathComponent(".helium-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let lease = try lockSourceDownloadCache(root, operation: LOCK_EX)
        defer { try? lease.close() }
        recoverHeliumInstallations(dataURL: root, verify: verifyFixture)
        #expect(!fm.fileExists(atPath: app.path))
        #expect(!fm.fileExists(atPath: backup.path))
        #expect(!fm.fileExists(atPath: staged.path))

        try writeHeliumApp(at: app, version: version)
        try fm.removeItem(at: app.appendingPathComponent("Contents/Resources/payload"))
        recoverHeliumInstallations(dataURL: root, verify: verifyFixture)
        #expect(!fm.fileExists(atPath: installed.path))
        try writeHeliumApp(at: app, version: version)

        // Simulate a crash immediately after the atomic swap: old directory
        // remains in staging while the new one is already resolvable.
        let replacement = staged.appendingPathComponent(version)
        try writeHeliumApp(at: replacement.appendingPathComponent("Helium.app"), version: version)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try publishHeliumDirectory(from: replacement, to: installed)
        #expect(!fm.fileExists(atPath: installed.appendingPathComponent("marker").path))
        #expect(fm.fileExists(atPath: replacement.appendingPathComponent("marker").path))
        recoverHeliumInstallations(dataURL: root, verify: verifyFixture)
        try verifyFixture(app)
        #expect(!fm.fileExists(atPath: staged.path))
    }

    @Test(arguments: ["detach", "delete", "inspect"])
    func busyHeliumCleanupDoesNotBlockOtherWork(failure: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let busy = root.appendingPathComponent(".helium-update-\(UUID().uuidString)")
        let removable = root.appendingPathComponent(".helium-update-\(UUID().uuidString)")
        for directory in [busy, removable] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let mount = busy.appendingPathComponent("mount").path
        try fm.createDirectory(atPath: mount, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["images": [["system-entities": [["mount-point": mount]]]]], format: .xml, options: 0)
        var logs: [String] = []
        recoverHeliumInstallations(dataURL: root, run: { _, args in
            if args[0] == "info" {
                if failure == "inspect" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
                return String(decoding: info, as: UTF8.self)
            }
            if failure == "detach" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
            return ""
        }, remove: { url in
            if url.lastPathComponent == busy.lastPathComponent && failure == "delete" {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
            }
            try fm.removeItem(at: url)
        }, log: { logs.append($0) })
        #expect(fm.fileExists(atPath: busy.path))
        #expect(fm.fileExists(atPath: removable.path) == (failure == "inspect"))
        #expect(logs.count == 1)
        // The setup pass can still publish another asset after cleanup fails.
        let download = root.appendingPathComponent("download.swbn")
        let destination = root.appendingPathComponent("darc/0.0.20/darc.swbn")
        let bytes = darcTestBundle(version: "0.0.20")
        try bytes.write(to: download)
        try installDarcSource(from: download, at: destination, expectedSHA256: darcTestChecksum(bytes))
        #expect(fm.fileExists(atPath: destination.path))
    }

    @Test func sha256IsCalculatedWithoutLoadingTheWholeAsset() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetDownloaderTests-\(UUID().uuidString)")
        try Data("Xe Computer\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try sha256Hex(of: file) == "da95635aa047927ccd16950021226df995bc38236c5a3db9675713af6276152c")
    }

    private func writeHeliumApp(at appURL: URL, version: String) throws {
        let contents = appURL.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Helium")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = ["CFBundleShortVersionString": version,
            "CFBundleIdentifier": "net.imput.helium", "CFBundleExecutable": "Helium", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        for directory in ["Resources", "Frameworks"] {
            let resource = contents.appendingPathComponent(directory + "/payload")
            try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
            if directory == "Frameworks" {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: resource)
            } else {
                try Data("sealed bytes".utf8).write(to: resource)
            }
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--deep", "--sign", "-", appURL.path]
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)
    }

    private func verifyFixture(_ app: URL) throws {
        try verifyApplicationSignature(at: app, requirement: "identifier \"net.imput.helium\"")
    }

    private func canonical(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
