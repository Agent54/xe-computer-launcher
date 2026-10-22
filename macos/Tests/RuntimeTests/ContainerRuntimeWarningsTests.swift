import AppKit
import Foundation
import Testing
@testable import macos

@MainActor
struct ContainerRuntimeWarningsTests {
    private func snapshot(available: UInt64 = 50, bootID: String = "boot-1") -> ContainerRuntimeSnapshot {
        ContainerRuntimeSnapshot(
            phase: .healthy, message: "Container runtime ready", reason: nil, updatedAt: Date(),
            recoveryAttempt: nil, memoryTotalBytes: 100, memoryAvailableBytes: available,
            oomKillCount: 0, hostResources: nil, bootId: bootID
        )
    }

    private func history() -> ContainerRuntimeSnapshot {
        var snapshot = snapshot()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        snapshot.lastIncident = ContainerRuntimeIncident(
            id: "oom-1", reason: "oom", message: "Linux killed Docker after VM memory ran out.",
            occurredAt: date, memoryLimitBytes: 4 << 30, restartedAt: date
        )
        snapshot.cachePressureWarning = .init(
            id: "cache-1", message: "Below 5% free disk; cleanup included cache younger than 32 hours.",
            occurredAt: date
        )
        return snapshot
    }

    @Test func ignoredHistoryCanBeReopenedAfterRelaunchAndNewIncidentsWarnAgain() throws {
        var ignored: [ContainerRuntimeWarnings.Kind: String] = [:]
        let read: (ContainerRuntimeWarnings.Kind) -> String? = { ignored[$0] }
        let save: (ContainerRuntimeWarnings.Kind, String) -> Void = { ignored[$0] = $1 }
        let warnings = ContainerRuntimeWarnings(readIgnored: read, saveIgnored: save)
        var current = history()
        warnings.update(current)
        #expect(warnings.unignoredCount == 2)
        for warning in warnings.warnings { warnings.ignore(warning) }
        #expect(warnings.unignoredCount == 0)
        #expect(warnings.warnings.count == 2)
        let relaunched = ContainerRuntimeWarnings(readIgnored: read, saveIgnored: save)
        relaunched.update(current)
        #expect(relaunched.unignoredCount == 0)
        #expect(relaunched.warnings.count == 2)
        let previous = try #require(relaunched.warnings.first { $0.kind == .cacheCleanup })
        current.cachePressureWarning = .init(id: "cache-2", message: "New cleanup", occurredAt: Date())
        relaunched.update(current)
        // A dialog for an older event must not acknowledge a newer cleanup.
        relaunched.ignore(previous)
        #expect(relaunched.unignoredCount == 1)
    }

    @Test func pressureAcknowledgementLastsUntilMemoryRecoversOrTheGuestChanges() throws {
        var ignored: [ContainerRuntimeWarnings.Kind: String] = [:]
        let warnings = ContainerRuntimeWarnings(readIgnored: { ignored[$0] }, saveIgnored: { ignored[$0] = $1 })
        warnings.update(snapshot(available: 10))
        let first = try #require(warnings.warnings.first)
        warnings.ignore(first)
        warnings.update(snapshot(available: 9))
        #expect(warnings.warnings.first?.id == first.id)
        #expect(warnings.unignoredCount == 0)
        warnings.update(snapshot(available: 11))
        #expect(warnings.warnings.isEmpty)
        warnings.update(snapshot(available: 5))
        #expect(warnings.unignoredCount == 1)
        let second = try #require(warnings.warnings.first)
        #expect(second.id != first.id)
        warnings.ignore(second)
        warnings.update(snapshot(available: 5, bootID: "boot-2"))
        #expect(warnings.unignoredCount == 1)
    }

    @Test func dialogsOfferTheRelevantResourceSettingAndIgnore() throws {
        _ = NSApplication.shared
        let warnings = ContainerRuntimeWarnings(readIgnored: { _ in nil }, saveIgnored: { _, _ in })
        var current = history()
        current = ContainerRuntimeSnapshot(
            phase: current.phase, message: current.message, reason: nil, updatedAt: current.updatedAt,
            recoveryAttempt: nil, memoryTotalBytes: 100, memoryAvailableBytes: 5, oomKillCount: 0,
            hostResources: nil, lastIncident: current.lastIncident, cachePressureWarning: current.cachePressureWarning
        )
        warnings.update(current)
        #expect(warnings.warnings.count == 3)
        for warning in warnings.warnings {
            let alert = ContainerRuntimeWarnings.alert(for: warning)
            #expect(alert.alertStyle == .warning)
            #expect(alert.messageText == warning.title)
            #expect(alert.buttons.count == 2)
            #expect(alert.buttons[1].title == "Ignore")
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
            if warning.kind == .cacheCleanup {
                #expect(warning.resource == .disk)
                #expect(alert.buttons[0].title == "Increase Disk Size…")
                #expect(alert.informativeText.contains("younger than 32 hours"))
            } else {
                #expect(warning.resource == .memory)
                #expect(alert.buttons[0].title == "Increase Memory…")
            }
        }
        let oom = try #require(warnings.warnings.first { $0.kind == .outOfMemory })
        #expect(oom.title.contains("Restarted"))
        #expect(oom.message.contains("Automatic VM restart:"))
        #expect(oom.message.contains("Container runtime ready"))
    }
}
