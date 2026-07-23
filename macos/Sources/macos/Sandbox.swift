import Foundation

/// Module for applying seatbelt sandbox profiles at runtime
enum Sandbox {
    
    /// Applies the sandbox profile from the app bundle's Resources directory
    /// - Returns: true if sandbox was applied successfully, false otherwise
    @discardableResult
    static func apply() -> Bool {
        guard let sandboxDir = Bundle.main.resourceURL?.appendingPathComponent("sandbox") else {
            print("[Sandbox] ERROR: sandbox directory not found")
            return false
        }
        
        let profileURL = sandboxDir.appendingPathComponent("xe-computer.sb")
        
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            print("[Sandbox] ERROR: profile not found at \(profileURL.path)")
            return false
        }
        
        do {
            let profile = try loadProfileWithImports(from: profileURL, baseDir: sandboxDir)
            let parameters = buildParameters()
            let success = apply(profile: profile, parameters: parameters)
            
            let paramSummary = parameters.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            print("[Sandbox] \(success ? "Applied" : "FAILED") (\(paramSummary))")
            
            return success
        } catch {
            print("[Sandbox] ERROR: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Builds the parameter dictionary for sandbox profile substitution
    private static func buildParameters() -> [String: String] {
        var params: [String: String] = [:]
        
        // HOME - user's home directory
        params["HOME"] = NSHomeDirectory()
        
        // BUNDLE_PATH - the app bundle path
        params["BUNDLE_PATH"] = Bundle.main.bundlePath
        
        // BUNDLE_DIR - parent directory of bundle (for dev builds)
        if let bundleDir = Bundle.main.bundleURL.deletingLastPathComponent().path.removingPercentEncoding {
            params["BUNDLE_DIR"] = bundleDir
        }
        
        // CWD - current working directory
        params["CWD"] = FileManager.default.currentDirectoryPath
        
        // USER - current username
        params["USER"] = NSUserName()
        
        return params
    }
    
    /// Loads a seatbelt profile and resolves (import "filename") directives
    /// - Parameters:
    ///   - url: URL of the profile to load
    ///   - baseDir: Directory to resolve relative imports from
    /// - Returns: The profile with all imports inlined
    private static func loadProfileWithImports(from url: URL, baseDir: URL) throws -> String {
        var imported: Set<String> = []
        return try loadProfileWithImports(from: url, baseDir: baseDir, imported: &imported)
    }
    
    /// Internal recursive implementation with import tracking
    private static func loadProfileWithImports(from url: URL, baseDir: URL, imported: inout Set<String>) throws -> String {
        let content = try String(contentsOf: url, encoding: .utf8)
        
        // Find (import "filename.sb") directives that are NOT in comments
        // Match only when (import is at start of line or after whitespace (not after ;;)
        let importPattern = #"(?m)^[^;]*\(import\s+"([^"]+)"\)"#
        let regex = try NSRegularExpression(pattern: importPattern, options: [])
        
        var result = content
        var offset = 0
        
        let matches = regex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
        
        for match in matches {
            guard let filenameRange = Range(match.range(at: 1), in: content),
                  let fullMatchRange = Range(match.range(at: 0), in: content) else {
                continue
            }
            
            let filename = String(content[filenameRange])
            
            // Skip if already imported (prevents cycles)
            guard !imported.contains(filename) else { continue }
            
            imported.insert(filename)
            let importURL = baseDir.appendingPathComponent(filename)
            
            // Recursively load imported file (supports nested imports)
            let importedContent = try loadProfileWithImports(from: importURL, baseDir: baseDir, imported: &imported)
            
            // We need to extract just the (import ...) part, not the whole line
            // Find the actual import statement within the match
            let matchedString = String(content[fullMatchRange])
            guard let importRange = matchedString.range(of: #"\(import\s+"[^"]+"\)"#, options: .regularExpression) else {
                continue
            }
            
            let importStatement = String(matchedString[importRange])
            let importStartInMatch = matchedString.distance(from: matchedString.startIndex, to: importRange.lowerBound)
            
            // Calculate adjusted range for just the import statement
            let adjustedStart = result.index(result.startIndex, offsetBy: content.distance(from: content.startIndex, to: fullMatchRange.lowerBound) + importStartInMatch + offset)
            let adjustedEnd = result.index(adjustedStart, offsetBy: importStatement.count)
            
            // Replace the import directive with the imported content
            result.replaceSubrange(adjustedStart..<adjustedEnd, with: importedContent)
            
            // Update offset for subsequent replacements
            offset += importedContent.count - importStatement.count
        }
        
        return result
    }
    
    /// Applies a sandbox profile string using sandbox_init_with_parameters
    /// - Parameters:
    ///   - profile: The seatbelt profile as a string
    ///   - parameters: Dictionary of parameter names to values for substitution
    /// - Returns: true if sandbox was applied successfully
    private static func apply(profile: String, parameters: [String: String]) -> Bool {
        var errorBuf: UnsafeMutablePointer<CChar>?
        
        // Build the parameters array for sandbox_init_with_parameters
        // Format: ["key1", "value1", "key2", "value2", ..., nil]
        // Using ContiguousArray and withUnsafeBufferPointer for safe C interop
        
        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        
        for (key, value) in parameters {
            cStrings.append(strdup(key))
            cStrings.append(strdup(value))
        }
        cStrings.append(nil) // Null terminator
        
        defer {
            // Free all the duplicated strings (except the nil terminator)
            for ptr in cStrings where ptr != nil {
                free(ptr)
            }
        }
        
        let result = profile.withCString { profileCString in
            cStrings.withUnsafeMutableBufferPointer { buffer in
                sandbox_init_with_parameters(profileCString, 0, buffer.baseAddress!, &errorBuf)
            }
        }
        
        if result != 0 {
            if let errorBuf = errorBuf {
                sandbox_free_error(errorBuf)
            }
            return false
        }
        
        return true
    }
}

// MARK: - sandbox.h bindings (private API, but stable and used by Chrome/Chromium)

@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_silgen_name("sandbox_init_with_parameters")
private func sandbox_init_with_parameters(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ parameters: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_silgen_name("sandbox_free_error")
private func sandbox_free_error(_ errorbuf: UnsafeMutablePointer<CChar>)
