import Foundation

/// UI rendering uses the last completed sample and never waits for discovery.
@MainActor
final class MenuServiceState {
    struct Snapshot: Sendable, Equatable {
        // An unsampled profile must not enable Start using assumed stopped state.
        var profile = ""
        var chromeRunning = false
        var darcRunning = false
    }

    private(set) var snapshot = Snapshot()
    private var refreshTask: Task<Void, Never>?

    func refresh(
        sample: @escaping @Sendable () -> Snapshot,
        didRefresh: @escaping @MainActor () -> Void
    ) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility, operation: sample).value
            guard let self else { return }
            self.snapshot = result
            self.refreshTask = nil
            didRefresh()
        }
    }
}
