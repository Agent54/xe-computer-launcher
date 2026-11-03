import Foundation

enum SystemLogSeverity: Int, Sendable {
    case info, warning, error

    static func classify(source: String, line: String) -> Self {
        if line.range(of: #"(?i)(?:^|\s)(?:error|fatal|panic):|:(?:error|fatal):|\[(?:error|fatal)\]|\blevel=(?:error|fatal|panic)\b|"(?:level|severity)"\s*:\s*"(?:error|fatal|panic)""#,
                      options: .regularExpression) != nil { return .error }
        let lower = line.lowercased()
        if lower.contains("exited unexpectedly")
            || lower.contains("shutdown exceeded")
            || lower.contains("shutdown finished (stopped=false)")
            || lower.hasPrefix("could not ") || lower.hasPrefix("failed to ")
            || lower.contains(" failed:") || lower.contains(" failed to start:") {
            return .error
        }
        if (source == "launcher" || source == "browser"),
           lower.range(of: #"(?:browser process exited \(code=|process exited with code )-?[1-9][0-9]*"#,
                       options: .regularExpression) != nil { return .error }
        if lower.range(of: #"(?:^|\s)warn(?:ing)?:|:warning:|\[warn(?:ing)?\]|\blevel=warn(?:ing)?\b|"(?:level|severity)"\s*:\s*"warn(?:ing)?""#,
                       options: .regularExpression) != nil { return .warning }
        if (lower.contains("did not exit after") && (lower.contains("sigterm") || lower.contains("sigkill")))
            || lower.hasPrefix("force-terminated zombie ") { return .warning }
        return .info
    }
}
