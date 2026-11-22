import AppKit
import Foundation
import Testing
@testable import macos

@MainActor
struct MenuPresentationTests {
    @Test func refreshPreservesRowsAndOpenSubmenus() throws {
        let rows = LiveMenuItems<String>()
        rows.update(keys: ["browser", "warnings"]) { key, item in
            item.title = key
            item.submenu = NSMenu()
        }
        let browser = rows.menu.item(at: 0)
        let warnings = try #require(rows.menu.item(at: 1))
        let submenu = warnings.submenu
        for index in 0..<10 {
            rows.update(keys: ["browser", "warnings"]) { _, item in
                item.title = "Updated \(index)"
                item.isEnabled = true
            }
        }
        #expect(rows.menu.item(at: 0) === browser)
        #expect(rows.menu.item(at: 1) === warnings)
        #expect(warnings.submenu === submenu)
        #expect(warnings.title == "Updated 9")
    }

    @Test func hierarchyChangesWaitForTrackingToEnd() throws {
        let rows = LiveMenuItems<String>()
        rows.update(keys: ["old", "current"]) { key, item in
            item.title = key
            item.isEnabled = true
        }
        let old = try #require(rows.menu.item(at: 0))
        let current = try #require(rows.menu.item(at: 1))
        rows.update(keys: ["current", "new"], deferStructuralChanges: true) { key, item in
            item.title = "Updated \(key)"
        }
        #expect(rows.menu.numberOfItems == 2)
        #expect(rows.menu.item(at: 0) === old)
        #expect(!old.isEnabled)
        #expect(rows.menu.item(at: 1) === current)
        #expect(current.title == "Updated current")
        rows.update(keys: ["current", "new"]) { key, item in item.title = key }
        #expect(rows.menu.item(at: 0) === current)
        #expect(rows.menu.item(at: 1)?.title == "new")
        #expect(old.menu == nil)
    }

    @Test func variantUpdatesLeaveServiceCommandsInPlace() {
        let menu = NSMenu()
        let start = menu.addItem(withTitle: "Start", action: nil, keyEquivalent: "")
        let stop = menu.addItem(withTitle: "Stop", action: nil, keyEquivalent: "")
        let rows = LiveMenuItems<String>(menu: menu)
        rows.update(keys: ["helium", "beta"]) { key, item in item.title = key }
        let helium = menu.item(at: 2)
        rows.update(keys: ["helium", "stable"]) { key, item in item.title = key }
        #expect(menu.item(at: 0) === start)
        #expect(menu.item(at: 1) === stop)
        #expect(menu.item(at: 2) === helium)
        #expect(menu.item(at: 3)?.title == "stable")
    }

    @Test func slowDiscoveryKeepsTheMainActorAvailableAndCoalescesRefreshes() async {
        let state = MenuServiceState()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let (events, continuation) = AsyncStream<Int>.makeStream()
        defer { continuation.finish() }
        var iterator = events.makeAsyncIterator()
        var updates = 0
        state.refresh(sample: {
            #expect(!Thread.isMainThread)
            continuation.yield(1)
            #expect(gate.wait(timeout: .now() + 5) == .success)
            return .init(profile: "work", chromeRunning: true, darcRunning: true)
        }, didRefresh: {
            updates += 1
            continuation.yield(2)
        })
        #expect(await iterator.next() == 1)
        // These main-actor operations must run while discovery is blocked.
        #expect(state.snapshot == .init())
        #expect(updates == 0)
        state.refresh(sample: {
            Issue.record("Overlapping discovery must be coalesced")
            return .init()
        }, didRefresh: { Issue.record("Unexpected overlapping refresh") })
        gate.signal()
        #expect(await iterator.next() == 2)
        #expect(state.snapshot.profile == "work")
        #expect(state.snapshot.chromeRunning)
        #expect(state.snapshot.darcRunning)
        #expect(updates == 1)

        state.refresh(sample: { .init(profile: "work") }, didRefresh: { continuation.yield(3) })
        #expect(await iterator.next() == 3)
        #expect(!state.snapshot.chromeRunning)
        #expect(!state.snapshot.darcRunning)
    }
}
