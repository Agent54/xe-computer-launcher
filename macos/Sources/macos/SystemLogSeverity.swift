import Foundation

enum SystemLogSeverity: Int, Codable, Sendable {
    case info, warning, error

    private static let errorPattern = try! NSRegularExpression(pattern: #"(?i)(?:^|\s)(?:error|fatal|panic):|:(?:error|fatal):|\[(?:error|fatal)\]|\blevel=(?:error|fatal|panic)\b|"(?:level|severity)"\s*:\s*"(?:error|fatal|panic)""#)
    private static let exitPattern = try! NSRegularExpression(pattern: #"(?:browser process exited \(code=|process exited with code )-?[1-9][0-9]*"#)
    private static let warningPattern = try! NSRegularExpression(pattern: #"(?:^|\s)warn(?:ing)?:|:warning:|\[warn(?:ing)?\]|\blevel=warn(?:ing)?\b|"(?:level|severity)"\s*:\s*"warn(?:ing)?""#)

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func classify(source: String, line: String) -> Self {
        if matches(errorPattern, line) { return .error }
        let lower = line.lowercased()
        if lower.contains("exited unexpectedly")
            || lower.contains("shutdown exceeded")
            || lower.contains("shutdown finished (stopped=false)")
            || (source == "runtime" && lower.hasPrefix("the container vm ran out of memory"))
            || lower.hasPrefix("could not ") || lower.hasPrefix("failed to ")
            || lower.contains(" failed:") || lower.contains(" failed to start:") {
            return .error
        }
        if (source == "launcher" || source == "browser"),
           matches(exitPattern, lower) { return .error }
        if matches(warningPattern, lower) { return .warning }
        if (lower.contains("did not exit after") && (lower.contains("sigterm") || lower.contains("sigkill")))
            || lower.hasPrefix("force-terminated zombie ") { return .warning }
        return .info
    }
}
