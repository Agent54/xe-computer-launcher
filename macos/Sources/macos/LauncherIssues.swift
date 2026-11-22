/// The tray shows one notice for errors that haven't been opened in System Logs.
@MainActor
final class LauncherIssues {
    static let title = "Issues Detected"

    private let readDismissed: () -> UInt64?
    private let saveDismissed: (UInt64) -> Void

    init(
        readDismissed: @escaping () -> UInt64? = {
            ExternalState.shared.stringSetting("runtime_dismissed_systemLog_id")
                .flatMap { $0.hasPrefix("log-") ? UInt64($0.dropFirst("log-".count)) : nil }
        },
        saveDismissed: @escaping (UInt64) -> Void = {
            ExternalState.shared.setStringSetting("runtime_dismissed_systemLog_id", "log-\($0)")
        }
    ) {
        self.readDismissed = readDismissed
        self.saveDismissed = saveDismissed
    }

    func pendingError(_ latestError: SystemLogStore.Entry?) -> SystemLogStore.Entry? {
        guard let latestError, latestError.id > (readDismissed() ?? 0) else { return nil }
        return latestError
    }

    func dismiss(_ error: SystemLogStore.Entry) { saveDismissed(error.id) }
}
