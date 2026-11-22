import Foundation

/// Observe the image-owned router through the exposed socket. Its process and
/// executable files belong to the VM image, not to a host deployment directory.
actor GuestRouter {
    static let shared = GuestRouter()
    private var nextCheck = Date.distantPast
    private var unavailable = false

    func reconcile() async throws {
        guard Date() >= nextCheck else {
            if unavailable { throw GuestRouterError.unavailable }
            return
        }
        guard await UnixSocketHTTP.isReady(at: SmolVMSetup.dockerSocketURL) else {
            nextCheck = Date().addingTimeInterval(1)
            return
        }
        nextCheck = Date().addingTimeInterval(1)
        guard await UnixSocketHTTP.isReady(at: SmolVMSetup.routerSocketURL, path: "/__xe_router_health") else {
            unavailable = true
            throw GuestRouterError.unavailable
        }
        unavailable = false
        nextCheck = Date().addingTimeInterval(15)
    }

    func reset() {
        nextCheck = .distantPast
        unavailable = false
    }
}

enum GuestRouterError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "The VM's application router is not ready. Check the runtime log for its startup error."
    }
}
