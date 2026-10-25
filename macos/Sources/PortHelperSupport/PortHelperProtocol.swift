public enum PortHelperProtocol {
    public static let version: Int64 = 2
    // Bump for any helper behavior or security fix that must replace an
    // already-running helper, even if the socket protocol stays compatible.
    public static let revision: Int64 = 1

    public static func supports(version: Int64, revision: Int64) -> Bool {
        // Helpers released before explicit revisions use the baseline behavior.
        let effectiveRevision = revision == 0 ? 1 : revision
        return version == Self.version && effectiveRevision == Self.revision
    }
}
