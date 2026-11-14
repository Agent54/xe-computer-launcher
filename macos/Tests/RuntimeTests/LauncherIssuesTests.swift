import Foundation
import Testing
@testable import macos

@MainActor
struct LauncherIssuesTests {
    @Test func dismissOnlyClearsTheErrorShown() {
        var dismissedID: UInt64?
        let issues = LauncherIssues(readDismissed: { dismissedID }, saveDismissed: { dismissedID = $0 })
        let error = SystemLogStore.Entry(id: 2, source: "browser", line: "Error: browser exited", timestamp: Date())
        let newer = SystemLogStore.Entry(id: 3, source: "runtime", line: "Error: VM ran out of memory", timestamp: Date())

        #expect(issues.pendingError(nil) == nil)
        #expect(issues.pendingError(error) == error)
        issues.dismiss(error)
        let relaunched = LauncherIssues(readDismissed: { dismissedID }, saveDismissed: { dismissedID = $0 })
        #expect(relaunched.pendingError(error) == nil)
        #expect(relaunched.pendingError(newer) == newer)
    }
}
