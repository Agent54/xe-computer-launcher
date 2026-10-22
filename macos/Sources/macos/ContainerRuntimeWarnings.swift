import AppKit
import Foundation

/// Launcher warning history and acknowledgements, independent of Compose UI dismissal.
@MainActor
final class ContainerRuntimeWarnings {
    enum Kind: String, Sendable {
        case memoryPressure, outOfMemory, cacheCleanup

        var settingKey: String { "runtime_ignored_\(rawValue)_id" }
    }

    struct Warning: Equatable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        let title: String
        let message: String
        let occurredAt: Date?

        var resource: ContainerVMSettings.Resource { kind == .cacheCleanup ? .disk : .memory }
        var actionTitle: String { kind == .cacheCleanup ? "Increase Disk Size…" : "Increase Memory…" }
    }

    private let readIgnored: (Kind) -> String?
    private let saveIgnored: (Kind, String) -> Void
    private var pressureID: String?
    private var pressureBootID: String?
    private(set) var warnings: [Warning] = []

    init(
        readIgnored: @escaping (Kind) -> String? = { ExternalState.shared.stringSetting($0.settingKey) },
        saveIgnored: @escaping (Kind, String) -> Void = { ExternalState.shared.setStringSetting($0.settingKey, $1) }
    ) {
        self.readIgnored = readIgnored
        self.saveIgnored = saveIgnored
    }

    var unignoredCount: Int { warnings.filter { !isIgnored($0) }.count }

    func isIgnored(_ warning: Warning) -> Bool { readIgnored(warning.kind) == warning.id }

    func ignore(_ warning: Warning) { saveIgnored(warning.kind, warning.id) }

    func update(_ snapshot: ContainerRuntimeSnapshot) {
        var current: [Warning] = []
        if snapshot.phase == .healthy, let total = snapshot.memoryTotalBytes, total > 0,
           let available = snapshot.memoryAvailableBytes, available <= total / 10 {
            if pressureID == nil || pressureBootID != snapshot.bootId {
                pressureID = UUID().uuidString
                pressureBootID = snapshot.bootId
            }
            if let pressureID {
                current.append(Warning(
                    id: pressureID, kind: .memoryPressure, title: "VM Memory Is Almost Full",
                    message: "Only 10% or less of VM memory is available. Pause builds or increase VM memory to avoid Linux killing processes.",
                    occurredAt: nil
                ))
            }
        } else if snapshot.phase == .healthy || snapshot.phase == .stopped {
            // A later pressure episode must warn again, even in the same VM boot.
            pressureID = nil
            pressureBootID = nil
        }
        if let incident = snapshot.lastIncident, incident.reason == "oom" {
            let restart = incident.restartedAt.map {
                "\n\nAutomatic VM restart: " + $0.formatted(date: .abbreviated, time: .shortened)
            } ?? ""
            current.append(Warning(
                id: incident.id, kind: .outOfMemory,
                title: incident.restartedAt == nil ? "Container VM Ran Out of Memory" : "VM Restarted After Running Out of Memory",
                message: incident.message + restart + "\n\nCurrent runtime status: " + snapshot.message,
                occurredAt: incident.occurredAt
            ))
        }
        if let warning = snapshot.cachePressureWarning {
            current.append(Warning(
                id: warning.id, kind: .cacheCleanup, title: "Low Disk Space Triggered Younger Cache Cleanup",
                message: warning.message, occurredAt: warning.occurredAt
            ))
        }
        warnings = current
    }

    static func alert(for warning: Warning) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.title
        alert.informativeText = warning.message
        if let occurredAt = warning.occurredAt {
            alert.informativeText += "\n\nOccurred: " + occurredAt.formatted(date: .abbreviated, time: .shortened)
        }
        alert.addButton(withTitle: warning.actionTitle)
        alert.addButton(withTitle: "Ignore").keyEquivalent = "\u{1b}"
        return alert
    }
}
