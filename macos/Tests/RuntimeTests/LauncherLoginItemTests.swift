import ServiceManagement
import Testing
@testable import macos

struct LauncherLoginItemTests {
    @Test func registrationFollowsThePreferenceAndIsIdempotent() throws {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let item = LauncherLoginItem(
            status: { status },
            register: { registrations += 1; status = .enabled },
            unregister: { removals += 1; status = .notRegistered }
        )
        try item.apply(enabled: false)
        #expect(removals == 0)
        try item.apply(enabled: true)
        try item.apply(enabled: true)
        #expect(registrations == 1)
        #expect(status == .enabled)
        try item.apply(enabled: false)
        try item.apply(enabled: false)
        #expect(removals == 1)
        #expect(status == .notRegistered)
    }

    @Test func pendingApprovalIsPreservedUntilExplicitlyDisabled() throws {
        var status = SMAppService.Status.requiresApproval
        let item = LauncherLoginItem(
            status: { status },
            register: { Issue.record("Do not repeatedly register or bypass macOS approval") },
            unregister: { status = .notRegistered }
        )
        try item.apply(enabled: true)
        #expect(status == .requiresApproval)
        try item.apply(enabled: false)
        #expect(status == .notRegistered)
    }

    @Test func registrationFailureReachesTheCaller() {
        enum Failure: Error { case denied }
        let item = LauncherLoginItem(
            status: { .notRegistered },
            register: { throw Failure.denied },
            unregister: {}
        )
        #expect(throws: Failure.denied) { try item.apply(enabled: true) }
    }
}
