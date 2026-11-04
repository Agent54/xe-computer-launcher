import Darwin
import Foundation
import Testing
@testable import macos

struct BrowserProcessOwnershipTests {
    private let data = URL(fileURLWithPath: "/Users/test/Library/Application Support/dev.xe.computer")

    @Test func shimIdentityRequiresTheManagedPath() {
        let expected = data.appendingPathComponent("shims/default/Xe Computer.app")
        let oldDarc = URL(fileURLWithPath: "/Applications/Darc.app")
        let loader = "Contents/MacOS/app_mode_loader"
        #expect(BrowserProcessOwnership.matchesShim(bundleURL: expected, executableURL: nil, expectedAppURL: expected))
        #expect(!BrowserProcessOwnership.matchesShim(bundleURL: oldDarc, executableURL: oldDarc.appendingPathComponent(loader), expectedAppURL: expected))
        // A stale pre-move bundle URL is safe only when the executable proves ownership.
        #expect(BrowserProcessOwnership.matchesShim(bundleURL: oldDarc, executableURL: expected.appendingPathComponent(loader), expectedAppURL: expected))
        #expect(!BrowserProcessOwnership.matchesShim(bundleURL: expected, executableURL: oldDarc.appendingPathComponent(loader), expectedAppURL: expected))
        #expect(!BrowserProcessOwnership.matchesShim(bundleURL: nil, executableURL: nil, expectedAppURL: expected))
    }

    @Test func profileArgumentsPreserveBoundariesAndSpaces() {
        let profile = data.appendingPathComponent("profiles/work -- project").path
        #expect(BrowserProcessOwnership.ownsBrowser(arguments: ["Helium", "--user-data-dir=\(profile)"], dataURL: data))
        for arguments in [
            ["Helium"],
            ["Helium", "--user-data-dir="],
            ["Helium", "--user-data-dir"],
            ["Chrome", "--user-data-dir", profile],
            ["Helium", "--user-data-dir=relative/profiles/default"],
            ["Helium", "--user-data-dir=\(data.path)/profiles-other/default"],
            ["Helium", "--user-data-dir=\(data.path)/profiles/../../Darc/default"],
            ["Helium", "--title=text --user-data-dir=\(profile)"],
            ["Helium", "https://example.com/?q=--user-data-dir=\(profile)"],
            ["Helium", "--", "--user-data-dir=\(profile)"],
            ["Helium", "--user-data-dir=\(profile)", "--user-data-dir=/other"],
            ["Helium", "--user-data-dir=\(profile)", "--user-data-dir"]
        ] {
            #expect(!BrowserProcessOwnership.ownsBrowser(arguments: arguments, dataURL: data))
        }
    }

    @Test func sharedEngineDoesNotEstablishOwnership() {
        let engine = data.appendingPathComponent("helium/1/Helium.app/Contents/MacOS/Helium").path
        let helper = data.appendingPathComponent("helium/1/Helium.app/Contents/Frameworks/Helium Helper").path
        let profile = "--user-data-dir=\(data.path)/profiles/default"
        let unrelatedProfile = "--user-data-dir=/Users/test/Library/Application Support/Darc/default"
        let processes: [BrowserProcessOwnership.ProcessSnapshot] = [
            .init(pid: 10, group: 10, executable: engine, arguments: [engine, profile]),
            .init(pid: 11, group: 10, executable: helper, arguments: [helper]),
            .init(pid: 12, group: 10, executable: engine, arguments: [engine, unrelatedProfile]),
            .init(pid: 20, group: 20, executable: engine, arguments: [engine, unrelatedProfile]),
            .init(pid: 21, group: 20, executable: helper, arguments: [helper]),
            .init(pid: 30, group: 30, executable: engine, arguments: [engine]),
            .init(pid: 40, group: 1, executable: engine, arguments: [engine, profile]),
            .init(pid: 41, group: 1, executable: helper, arguments: [helper]),
            .init(pid: 50, group: 50, executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", arguments: ["Chrome", profile]),
            .init(pid: 60, group: 60, executable: "\(data.path)/shims/default/Xe Computer.app/Contents/MacOS/app_mode_loader", arguments: []),
            .init(pid: 61, group: 61, executable: "/Applications/Darc.app/Contents/MacOS/app_mode_loader", arguments: [])
        ]
        let owned = BrowserProcessOwnership.staleProcesses(processes, dataURL: data, ownPID: 99, browserGroup: 0)
        #expect(owned.map(\.pid) == [10, 11, 40, 50, 60])
        let current = BrowserProcessOwnership.staleProcesses(processes, dataURL: data, ownPID: 99, browserGroup: 10)
        #expect(current.map(\.pid) == [40, 50, 60])
    }

    @Test func kernelArgumentsExcludeEnvironmentAndRejectTruncation() {
        let arguments = ["/Applications/Helium", "--user-data-dir=\(data.path)/profiles/with spaces", "", "--headless=new"]
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/Applications/Helium\0\0\0".utf8)
        for argument in arguments { bytes += Array(argument.utf8) + [0] }
        bytes += Array("UNRELATED=--user-data-dir=/other\0".utf8)
        #expect(BrowserProcessOwnership.decodeArguments(bytes) == arguments)
        #expect(BrowserProcessOwnership.decodeArguments(Array(bytes.prefix(8))) == nil)
        #expect(BrowserProcessOwnership.decodeArguments([]) == nil)
    }

    @Test func readsLiveProcessArgumentsAndExecutable() throws {
        let arguments = try #require(BrowserProcessOwnership.arguments(pid: getpid()))
        #expect(arguments == ProcessInfo.processInfo.arguments)
        #expect(BrowserProcessOwnership.executableURL(pid: getpid()) != nil)
    }
}
