import Foundation

/// Observe the image-owned router through the exposed socket. Its process and
/// executable files belong to the VM image, not to a host deployment directory.
actor GuestRouter {
    static let shared = GuestRouter()
    private var nextCheck = Date.distantPast

    func reconcile() async throws {
        guard Date() >= nextCheck else { return }
        guard await UnixSocketHTTP.isReady(at: SmolVMSetup.dockerSocketURL) else {
            nextCheck = Date().addingTimeInterval(1)
            return
        }
        nextCheck = Date().addingTimeInterval(1)
        guard await UnixSocketHTTP.isReady(at: SmolVMSetup.routerSocketURL, path: "/__xe_router_health") else {
            throw GuestRouterError.unavailable
        }
        nextCheck = Date().addingTimeInterval(15)
    }

    func reset() { nextCheck = .distantPast }
}

enum GuestRouterError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "The VM's application router is not ready. Check the runtime log for its startup error."
    }
}
