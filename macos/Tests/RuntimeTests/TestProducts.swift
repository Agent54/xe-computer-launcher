import Foundation

private final class RuntimeTestBundle: NSObject {}

enum TestProducts {
    static let directory = Bundle(for: RuntimeTestBundle.self).bundleURL.deletingLastPathComponent()

    static func executable(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
