import Foundation
import CryptoKit
@testable import macos

// Runtime tests model the opaque release bytes recorded in a checksum pin.
func darcTestBundle(version: String, identity: String = trustedXeComputerWebBundleID) -> Data {
    Data("webBundleId".utf8) + Data([0x78, UInt8(identity.utf8.count)]) + Data(identity.utf8)
        + Data(" version=\(version) payload".utf8)
}

func darcTestChecksum(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
