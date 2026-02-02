import SwiftAgents
import Foundation

// MARK: - ToolError

/// Unified error type for all NanoClaw tools.
public enum ToolError: Error, Sendable {
    case fileNotFound(String)
    case directoryNotFound(String)
    case invalidPattern(String)
    case executionFailed(String)
    case timeout(command: String)
    case commandFailed(command: String, exitCode: Int, output: String)
}

// MARK: - Path Helpers

private func resolveBasePath() -> String {
    ProcessInfo.processInfo.environment["NANOCLAW_BASE_PATH"] ?? "/workspace/group"
}

private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    return "\(resolveBasePath())/\(path)"
}

// MARK: - ReadTool

/// Tool for reading files from the filesystem.
public struct ReadTool: Tool, Sendable {
    public let name = "read"
    public let description = "Reads a file from the filesystem"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "file_path", description: "Path to the file (relative to /workspace/group)", type: .string),
        ToolParameter(name: "limit", description: "Maximum number of lines to read (optional)", type: .int, isRequired: false)
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let filePath = arguments["file_path"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing file_path parameter")
        }
        
        let fullPath = resolvePath(filePath)
        
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw ToolError.fileNotFound(filePath)
        }
        
        let url = URL(fileURLWithPath: fullPath)
        let content = try String(contentsOf: url, encoding: .utf8)
        
        if let limit = arguments["limit"]?.intValue, limit > 0 {
            let lines = content.components(separatedBy: CharacterSet.newlines)
            return .string(lines.prefix(limit).joined(separator: "\n"))
        }
        
        return .string(content)
    }
}

// MARK: - WriteTool

/// Tool for writing content to files.
public struct WriteTool: Tool, Sendable {
    public let name = "write"
    public let description = "Writes content to a file"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "file_path", description: "Path to the file (relative to /workspace/group)", type: .string),
        ToolParameter(name: "content", description: "Content to write", type: .string),
        ToolParameter(name: "append", description: "Whether to append or overwrite (default: false)", type: .bool, isRequired: false, defaultValue: .bool(false))
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let filePath = arguments["file_path"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing file_path parameter")
        }
        guard let content = arguments["content"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing content parameter")
        }
        
        let fullPath = resolvePath(filePath)
        let url = URL(fileURLWithPath: fullPath)
        
        // Ensure parent directory exists
        let dirURL = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dirURL.path) {
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        
        let append = arguments["append"]?.boolValue ?? false
        
        if append && FileManager.default.fileExists(atPath: fullPath) {
            let existing = try String(contentsOf: url, encoding: .utf8)
            let newContent = existing + "\n" + content
            try newContent.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        
        return .string("Successfully wrote to \(filePath)")
    }
}

// MARK: - EditTool

/// Tool for finding and replacing text in files.
public struct EditTool: Tool, Sendable {
    public let name = "edit"
    public let description = "Find and replace text in files"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "file_path", description: "Path to the file (relative to /workspace/group)", type: .string),
        ToolParameter(name: "find", description: "Text to find (string or regex)", type: .string),
        ToolParameter(name: "replace", description: "Replacement text", type: .string),
        ToolParameter(name: "use_regex", description: "Use regex matching (default: false)", type: .bool, isRequired: false, defaultValue: .bool(false))
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let filePath = arguments["file_path"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing file_path parameter")
        }
        guard let find = arguments["find"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing find parameter")
        }
        guard let replace = arguments["replace"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing replace parameter")
        }
        
        let fullPath = resolvePath(filePath)
        
        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw ToolError.fileNotFound(filePath)
        }
        
        let url = URL(fileURLWithPath: fullPath)
        var content = try String(contentsOf: url, encoding: .utf8)
        
        let useRegex = arguments["use_regex"]?.boolValue ?? false
        let options: String.CompareOptions = useRegex ? .regularExpression : []
        let originalContent = content
        
        content = content.replacingOccurrences(of: find, with: replace, options: options)
        
        guard content != originalContent else {
            return .string("No changes made (text not found)")
        }
        
        // Atomic write
        try content.write(to: url, atomically: true, encoding: .utf8)
        
        // Count replacements
        let count = originalContent.components(separatedBy: find).count - 1
        
        return .string("Successfully made \(count) replacement(s) in \(filePath)")
    }
}

// MARK: - GlobTool

/// Tool for listing files matching a glob pattern.
public struct GlobTool: Tool, Sendable {
    public let name = "glob"
    public let description = "Lists files matching a glob pattern"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "pattern", description: "Glob pattern (e.g., '*.swift', 'docs/**/*.md')", type: .string)
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let pattern = arguments["pattern"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing pattern parameter")
        }
        
        let basePath = resolveBasePath()
        let results = try glob(pattern: pattern, in: basePath)
        return .string(results.joined(separator: "\n"))
    }
    
    private func glob(pattern: String, in basePath: String) throws -> [String] {
        var results: [String] = []
        
        let baseURL = URL(fileURLWithPath: basePath)
        
        if pattern.contains("**") {
            // Recursive search using URL-based enumerator
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: nil
            )
            
            while let url = enumerator?.nextObject() as? URL {
                let path = url.path.replacingOccurrences(of: basePath + "/", with: "")
                if matchesGlob(path, pattern: pattern) {
                    results.append(path)
                }
            }
        } else {
            // Single directory
            let dirPattern = (pattern as NSString).deletingLastPathComponent
            let filePattern = (pattern as NSString).lastPathComponent
            let searchURL = dirPattern.isEmpty ? baseURL : baseURL.appendingPathComponent(dirPattern)
            
            let items = try FileManager.default.contentsOfDirectory(at: searchURL, includingPropertiesForKeys: nil)
            for item in items {
                let itemName = item.lastPathComponent
                if matchesSimplePattern(itemName, pattern: filePattern) {
                    results.append(dirPattern.isEmpty ? itemName : "\(dirPattern)/\(itemName)")
                }
            }
        }
        
        return results.sorted()
    }
    
    private func matchesGlob(_ path: String, pattern: String) -> Bool {
        let regexPattern = pattern
            .replacingOccurrences(of: "**", with: ".*")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "?", with: "[^/]")
        return path.range(of: regexPattern, options: .regularExpression) != nil
    }
    
    private func matchesSimplePattern(_ filename: String, pattern: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*") && pattern.hasSuffix("*") {
            let middle = pattern.dropFirst().dropLast()
            return filename.contains(middle)
        }
        if pattern.hasPrefix("*") {
            return filename.hasSuffix(String(pattern.dropFirst()))
        }
        if pattern.hasSuffix("*") {
            return filename.hasPrefix(String(pattern.dropLast()))
        }
        return filename == pattern
    }
}

// MARK: - GrepTool

/// Tool for searching file content for patterns.
public struct GrepTool: Tool, Sendable {
    public let name = "grep"
    public let description = "Searches file content for patterns"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "pattern", description: "Search pattern (string or regex)", type: .string),
        ToolParameter(name: "file_pattern", description: "Glob pattern for files to search (e.g., '*.swift')", type: .string),
        ToolParameter(name: "use_regex", description: "Whether to use regex matching (default: true)", type: .bool, isRequired: false, defaultValue: .bool(true))
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let pattern = arguments["pattern"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing pattern parameter")
        }
        guard let filePattern = arguments["file_pattern"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing file_pattern parameter")
        }
        
        let basePath = resolveBasePath()
        let globTool = GlobTool()
        let globResult = try await globTool.execute(arguments: [
            "pattern": .string(filePattern)
        ])
        
        guard let filesString = globResult.stringValue, !filesString.isEmpty else {
            return .string("No files found matching pattern")
        }
        
        let fileList = filesString.components(separatedBy: CharacterSet.newlines)
        let useRegex = arguments["use_regex"]?.boolValue ?? true
        
        var matches: [String] = []
        
        for file in fileList where !file.isEmpty {
            let fullPath = "\(basePath)/\(file)"
            guard FileManager.default.fileExists(atPath: fullPath) else { continue }
            
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let lines = content.components(separatedBy: CharacterSet.newlines)
            
            for (index, line) in lines.enumerated() {
                if matchesPattern(line, pattern: pattern, useRegex: useRegex) {
                    matches.append("\(file):\(index + 1):\(line)")
                }
            }
        }
        
        return .string(matches.joined(separator: "\n"))
    }
    
    private func matchesPattern(_ text: String, pattern: String, useRegex: Bool) -> Bool {
        if useRegex {
            return text.range(of: pattern, options: .regularExpression) != nil
        } else {
            return text.contains(pattern)
        }
    }
}

// MARK: - BashTool

/// Tool for executing bash commands in the container.
public struct BashTool: Tool, Sendable {
    public let name = "bash"
    public let description = "Executes a bash command in the container"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "command", description: "The command to execute", type: .string),
        ToolParameter(name: "working_dir", description: "Working directory (relative to /workspace/group)", type: .string, isRequired: false),
        ToolParameter(name: "timeout", description: "Timeout in seconds (default: 60)", type: .int, isRequired: false, defaultValue: .int(60))
    ]
    
    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let command = arguments["command"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing command parameter")
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        
        if let workingDir = arguments["working_dir"]?.stringValue {
            process.currentDirectoryURL = URL(fileURLWithPath: resolvePath(workingDir))
        } else {
            process.currentDirectoryURL = URL(fileURLWithPath: resolveBasePath())
        }
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        // Wait with timeout
        let timeout = arguments["timeout"]?.intValue ?? 60
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        
        if process.isRunning {
            process.terminate()
            throw ToolError.timeout(command: command)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        guard process.terminationStatus == 0 else {
            throw ToolError.commandFailed(
                command: command,
                exitCode: Int(process.terminationStatus),
                output: output
            )
        }
        
        return .string(output)
    }
}
