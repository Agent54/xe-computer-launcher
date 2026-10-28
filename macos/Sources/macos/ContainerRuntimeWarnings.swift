import AppKit
import Foundation

/// Launcher warning history and acknowledgements, independent of Compose UI dismissal.
@MainActor
final class ContainerRuntimeWarnings {
    enum Kind: String, Sendable {
        case memoryPressure, outOfMemory, cacheCleanup, hostMemory, hostDisk

        var settingKey: String { "runtime_ignored_\(rawValue)_id" }
    }

    struct Warning: Equatable, Identifiable, Sendable {
        let id: String
        let kind: Kind
        let title: String
        let message: String
        let occurredAt: Date?

        var isHostWarning: Bool { kind == .hostMemory || kind == .hostDisk }
        var resource: ContainerVMSettings.Resource? { isHostWarning ? nil : kind == .cacheCleanup ? .disk : .memory }
        var actionTitle: String { isHostWarning ? "OK" : kind == .cacheCleanup ? "Increase Disk Size…" : "Increase Memory…" }
    }

    private let readIgnored: (Kind) -> String?
    private let saveIgnored: (Kind, String) -> Void
    private var pressureID: String?
    private var pressureBootID: String?
    private var hostEpisodeIDs: [Kind: String] = [:]
    private var presentedIDs: [Kind: Set<String>] = [:]
    private(set) var warnings: [Warning] = []

    init(
        readIgnored: @escaping (Kind) -> String? = { ExternalState.shared.stringSetting($0.settingKey) },
        saveIgnored: @escaping (Kind, String) -> Void = { ExternalState.shared.setStringSetting($0.settingKey, $1) }
    ) {
        self.readIgnored = readIgnored
        self.saveIgnored = saveIgnored
    }

    var unignoredCount: Int { warnings.filter { !isIgnored($0) }.count }
    var hasHostWarning: Bool { warnings.contains { $0.isHostWarning } }

    func isIgnored(_ warning: Warning) -> Bool { readIgnored(warning.kind) == warning.id }

    func ignore(_ warning: Warning) { saveIgnored(warning.kind, warning.id) }

    /// Keep a dismissed dialog from reopening on every status refresh. New episodes
    /// have new IDs, while ignored events remain suppressed across launcher runs.
    var nextAutomaticWarning: Warning? {
        warnings.first { !isIgnored($0) && !(presentedIDs[$0.kind]?.contains($0.id) ?? false) }
    }

    func didPresent(_ warning: Warning) { presentedIDs[warning.kind, default: []].insert(warning.id) }

    func update(_ snapshot: ContainerRuntimeSnapshot) {
        var current: [Warning] = []
        var activeHostKinds: Set<Kind> = []
        for warning in HostResourcePolicy.warnings(for: snapshot.hostResources) {
            let kind: Kind = warning.resource == .memory ? .hostMemory : .hostDisk
            activeHostKinds.insert(kind)
            let id = hostEpisodeIDs[kind] ?? UUID().uuidString
            hostEpisodeIDs[kind] = id
            current.append(Warning(id: id, kind: kind,
                title: kind == .hostMemory ? "Host RAM Below 4 GiB Reserve" : "Host Disk Below 10 GiB Reserve",
                message: warning.message, occurredAt: nil))
        }
        hostEpisodeIDs = hostEpisodeIDs.filter { activeHostKinds.contains($0.key) }
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
                id: warning.id, kind: .cacheCleanup, title: "VM Disk Space Is Low",
                message: warning.message, occurredAt: warning.occurredAt
            ))
        }
        warnings = current
    }

    static func alert(for warning: Warning, actionTitle: String? = nil, blockedReason: String? = nil,
                      hostWarnings: [HostResourceReserveWarning] = []) -> NSAlert {
        let alert = warning.isHostWarning ? hostResourceAlert(title: warning.title, message: warning.message) : NSAlert()
        if !warning.isHostWarning { alert.alertStyle = .warning }
        alert.messageText = warning.title
        if !warning.isHostWarning { alert.informativeText = warning.message }
        if let occurredAt = warning.occurredAt {
            alert.informativeText += "\n\nOccurred: " + occurredAt.formatted(date: .abbreviated, time: .shortened)
        }
        let increase = alert.addButton(withTitle: actionTitle ?? warning.actionTitle)
        increase.isEnabled = blockedReason == nil
        if !warning.isHostWarning {
            let redMessages = hostWarnings.map(\.message) + (blockedReason.map { [$0] } ?? [])
            if !redMessages.isEmpty { alert.accessoryView = redLabel(redMessages.joined(separator: "\n\n")) }
        }
        alert.addButton(withTitle: "Ignore")
        alert.addButton(withTitle: "Dismiss").keyEquivalent = "\u{1b}"
        return alert
    }

    static func hostResourceAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.icon = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "Host resource warning")?
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        alert.accessoryView = redLabel(message)
        return alert
    }

    private static func redLabel(_ message: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 360, height: 1000)).height ?? 100
        label.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        return label
    }
}
