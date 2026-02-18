import SwiftAgents
import Configuration
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

private func environmentValue(_ key: String) -> String? {
    if #available(macOS 15.0, iOS 18.0, *) {
        let reader = ConfigReader(
            provider: EnvironmentVariablesProvider(
                environmentVariables: ProcessInfo.processInfo.environment
            )
        )
        let value = reader.string(forKey: ConfigKey(key), default: "")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    let value = ProcessInfo.processInfo.environment[key] ?? ""
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func resolveBasePath() -> String {
    environmentValue("NANOCLAW_BASE_PATH") ?? "/workspace/group"
}

private func resolveSharedMemoryRootPath() -> String {
    environmentValue("NANOCLAW_SHARED_MEMORY_PATH") ?? "/workspace/shared-memory"
}

private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    return "\(resolveBasePath())/\(path)"
}

private func resolveGroupFolderForTools() -> String {
    if let value = environmentValue("NANOCLAW_GROUP_FOLDER") {
        return value
    }
    return "default"
}

// MARK: - MCPStatusTool

public struct MCPStatusTool: Tool, Sendable {
    public let name = "mcp_status"
    public let description = "Shows MCP runtime startup status, loaded servers, and skipped diagnostics"
    public let parameters: [ToolParameter] = []
    private let status: MCPRuntimeStatus

    public init(status: MCPRuntimeStatus) {
        self.status = status
    }

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        _ = arguments
        let loadedServers = status.loadedServerIDs.isEmpty ? "none" : status.loadedServerIDs.joined(separator: ", ")
        let skippedServers = status.skippedServers.isEmpty
            ? "none"
            : status.skippedServers
                .map { "\($0.id)(\($0.reason.rawValue))" }
                .joined(separator: ", ")
        let diagnostics = status.diagnostics.isEmpty ? "none" : status.diagnostics.joined(separator: "; ")

        let lines = [
            "MCP Runtime Status",
            "Config found: \(status.hasConfig ? "yes" : "no")",
            "Configured servers: \(status.configuredServerCount)",
            "Loaded servers: \(loadedServers)",
            "Loaded tools: \(status.loadedToolCount)",
            "Skipped servers: \(skippedServers)",
            "Diagnostics: \(diagnostics)"
        ]
        return .string(lines.joined(separator: "\n"))
    }
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
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Pattern cannot be empty")
        }
        
        let basePath = resolveBasePath()
        let results = try glob(pattern: normalizedPattern, in: basePath)
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
            let dirPattern: String
            let filePattern: String
            if let slash = pattern.lastIndex(of: "/") {
                dirPattern = String(pattern[..<slash])
                filePattern = String(pattern[pattern.index(after: slash)...])
            } else {
                dirPattern = ""
                filePattern = pattern
            }
            guard !filePattern.isEmpty else {
                throw AgentError.invalidToolArguments(toolName: name, reason: "Invalid pattern: missing filename segment")
            }
            let searchURL = dirPattern.isEmpty ? baseURL : baseURL.appendingPathComponent(dirPattern)

            guard FileManager.default.fileExists(atPath: searchURL.path) else {
                return []
            }

            let items = try FileManager.default.contentsOfDirectory(
                at: searchURL,
                includingPropertiesForKeys: nil
            )
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

// MARK: - Todo Tools

private struct TodoSnapshot: Codable, Sendable {
    var version: Int = 1
    var items: [String] = []
}

private func resolveTodoSnapshotPath() -> String {
    "\(resolveBasePath())/.nanoclaw/todo.json"
}

private func loadTodoSnapshot() throws -> TodoSnapshot {
    let path = resolveTodoSnapshotPath()
    guard FileManager.default.fileExists(atPath: path) else {
        return TodoSnapshot()
    }

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if data.isEmpty {
            return TodoSnapshot()
        }
        return try JSONDecoder().decode(TodoSnapshot.self, from: data)
    } catch {
        throw ToolError.executionFailed("Failed to read TODO snapshot")
    }
}

private func saveTodoSnapshot(_ snapshot: TodoSnapshot) throws {
    let path = resolveTodoSnapshotPath()
    let url = URL(fileURLWithPath: path)
    let dirURL = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: dirURL.path) {
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    } catch {
        throw ToolError.executionFailed("Failed to persist TODO snapshot")
    }
}

/// Tool for reading TODO items from group-local storage.
public struct TodoReadTool: Tool, Sendable {
    public let name = "todo_read"
    public let description = "Reads TODO items for the current group"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "limit", description: "Maximum number of items to return (optional)", type: .int, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let snapshot = try loadTodoSnapshot()
        guard !snapshot.items.isEmpty else {
            return .string("No TODO items.")
        }

        let limitedItems: [String]
        if let limit = arguments["limit"]?.intValue, limit > 0 {
            limitedItems = Array(snapshot.items.prefix(limit))
        } else {
            limitedItems = snapshot.items
        }

        let rendered = limitedItems.enumerated().map { index, item in
            "\(index + 1). \(item)"
        }.joined(separator: "\n")
        return .string(rendered)
    }
}

/// Tool for mutating TODO items in group-local storage.
public struct TodoWriteTool: Tool, Sendable {
    public let name = "todo_write"
    public let description = "Adds, removes, replaces, or clears TODO items for the current group"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "action", description: "One of: add, remove, replace, clear", type: .string),
        ToolParameter(name: "item", description: "TODO item text (required for add/replace, optional for remove)", type: .string, isRequired: false),
        ToolParameter(name: "index", description: "1-based TODO item index (optional for remove, required for replace)", type: .int, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let rawAction = arguments["action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAction.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing action parameter")
        }
        let action = rawAction.lowercased()
        let item = arguments["item"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = arguments["index"]?.intValue

        var snapshot = try loadTodoSnapshot()

        switch action {
        case "add":
            guard let item, !item.isEmpty else {
                throw AgentError.invalidToolArguments(toolName: name, reason: "Missing item for add action")
            }
            snapshot.items.append(item)
            try saveTodoSnapshot(snapshot)
            return .string("Added TODO item. Total items: \(snapshot.items.count)")

        case "remove":
            if let index {
                guard (1...snapshot.items.count).contains(index) else {
                    throw AgentError.invalidToolArguments(toolName: name, reason: "index out of range")
                }
                snapshot.items.remove(at: index - 1)
            } else if let item, !item.isEmpty {
                guard let found = snapshot.items.firstIndex(of: item) else {
                    throw AgentError.invalidToolArguments(toolName: name, reason: "item not found")
                }
                snapshot.items.remove(at: found)
            } else {
                throw AgentError.invalidToolArguments(toolName: name, reason: "remove requires index or item")
            }
            try saveTodoSnapshot(snapshot)
            return .string("Removed TODO item. Total items: \(snapshot.items.count)")

        case "replace":
            guard let item, !item.isEmpty else {
                throw AgentError.invalidToolArguments(toolName: name, reason: "Missing item for replace action")
            }
            guard let index, (1...snapshot.items.count).contains(index) else {
                throw AgentError.invalidToolArguments(toolName: name, reason: "replace requires valid index")
            }
            snapshot.items[index - 1] = item
            try saveTodoSnapshot(snapshot)
            return .string("Replaced TODO item at index \(index). Total items: \(snapshot.items.count)")

        case "clear":
            snapshot.items.removeAll()
            try saveTodoSnapshot(snapshot)
            return .string("Cleared TODO items.")

        default:
            throw AgentError.invalidToolArguments(toolName: name, reason: "Unsupported action: \(rawAction)")
        }
    }
}

// MARK: - Memory Tools

public enum MemoryScope: String, Sendable, CaseIterable {
    case global
    case chat
}

public enum MemoryWriteMode: String, Sendable, CaseIterable {
    case replace
    case append
}

public struct MemoryReadResult: Sendable, Equatable {
    public let scope: MemoryScope
    public let content: String
    public let bytes: Int

    public init(scope: MemoryScope, content: String, bytes: Int) {
        self.scope = scope
        self.content = content
        self.bytes = bytes
    }
}

public struct MemoryWriteResult: Sendable, Equatable {
    public let scope: MemoryScope
    public let mode: MemoryWriteMode
    public let bytes: Int

    public init(scope: MemoryScope, mode: MemoryWriteMode, bytes: Int) {
        self.scope = scope
        self.mode = mode
        self.bytes = bytes
    }
}

public protocol MemoryStore: Sendable {
    func read(scope: MemoryScope) async throws -> MemoryReadResult
    func write(scope: MemoryScope, mode: MemoryWriteMode, content: String) async throws -> MemoryWriteResult
    func contextSnippet(tokenBudget: Int) async throws -> String
}

public actor FileMemoryStore: MemoryStore {
    public let chatMemoryFile: URL
    public let globalMemoryFile: URL
    private let fileManager = FileManager.default

    public init(chatMemoryFile: URL, globalMemoryFile: URL) {
        self.chatMemoryFile = chatMemoryFile.standardizedFileURL
        self.globalMemoryFile = globalMemoryFile.standardizedFileURL
    }

    public nonisolated static func `default`() -> FileMemoryStore {
        let chatMemoryFile = URL(fileURLWithPath: resolveBasePath())
            .appendingPathComponent(".nanoclaw")
            .appendingPathComponent("memory")
            .appendingPathComponent("chat.md")
        let globalMemoryFile = URL(fileURLWithPath: resolveSharedMemoryRootPath())
            .appendingPathComponent("global.md")
        return FileMemoryStore(chatMemoryFile: chatMemoryFile, globalMemoryFile: globalMemoryFile)
    }

    public func read(scope: MemoryScope) async throws -> MemoryReadResult {
        let url = url(for: scope)
        guard fileManager.fileExists(atPath: url.path) else {
            return MemoryReadResult(scope: scope, content: "", bytes: 0)
        }

        do {
            let data = try Data(contentsOf: url)
            let content = String(data: data, encoding: .utf8) ?? ""
            return MemoryReadResult(scope: scope, content: content, bytes: data.count)
        } catch {
            throw ToolError.executionFailed("Failed reading \(scope.rawValue) memory")
        }
    }

    public func write(scope: MemoryScope, mode: MemoryWriteMode, content: String) async throws -> MemoryWriteResult {
        let url = url(for: scope)
        do {
            try ensureParentDirectoryExists(for: url)

            let payload: String
            switch mode {
            case .replace:
                payload = content
            case .append:
                if fileManager.fileExists(atPath: url.path),
                   let existing = try? String(contentsOf: url, encoding: .utf8),
                   !existing.isEmpty {
                    payload = "\(existing)\n\(content)"
                } else {
                    payload = content
                }
            }

            try payload.write(to: url, atomically: true, encoding: .utf8)
            let bytes = payload.lengthOfBytes(using: .utf8)
            return MemoryWriteResult(scope: scope, mode: mode, bytes: bytes)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.executionFailed("Failed writing \(scope.rawValue) memory")
        }
    }

    public func contextSnippet(tokenBudget: Int) async throws -> String {
        let budget = max(50, tokenBudget)
        let global = try await read(scope: .global).content.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = try await read(scope: .chat).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !global.isEmpty || !chat.isEmpty else {
            return ""
        }

        var sections: [String] = []
        var remaining = budget

        func estimatedTokens(_ value: String) -> Int {
            max(1, value.count / 4)
        }

        if !global.isEmpty, remaining > 0 {
            let allowedChars = max(0, remaining * 4)
            let clipped = String(global.prefix(allowedChars))
            sections.append("### Global Memory\n\(clipped)")
            remaining -= estimatedTokens(clipped)
        }

        if !chat.isEmpty, remaining > 0 {
            let allowedChars = max(0, remaining * 4)
            let clipped = String(chat.prefix(allowedChars))
            sections.append("### Chat Memory\n\(clipped)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func url(for scope: MemoryScope) -> URL {
        switch scope {
        case .chat:
            return chatMemoryFile
        case .global:
            return globalMemoryFile
        }
    }

    private func ensureParentDirectoryExists(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Tool for reading persisted memory snippets.
public struct ReadMemoryTool: Tool, Sendable {
    public let name = "read_memory"
    public let description = "Reads persistent memory content for chat or global scope"
    public let parameters: [ToolParameter] = [
        ToolParameter(
            name: "scope",
            description: "Memory scope: chat or global (default: chat)",
            type: .string,
            isRequired: false,
            defaultValue: .string("chat")
        )
    ]

    private let store: any MemoryStore

    public init(store: any MemoryStore = FileMemoryStore.default()) {
        self.store = store
    }

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let scope = try parseScope(arguments: arguments)
        let result = try await store.read(scope: scope)
        if result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .string("No memory stored for scope=\(scope.rawValue).")
        }
        return .string(result.content)
    }
}

/// Tool for mutating persisted memory snippets.
public struct WriteMemoryTool: Tool, Sendable {
    public let name = "write_memory"
    public let description = "Writes persistent memory content for chat or global scope"
    public let parameters: [ToolParameter] = [
        ToolParameter(
            name: "scope",
            description: "Memory scope: chat or global (default: chat)",
            type: .string,
            isRequired: false,
            defaultValue: .string("chat")
        ),
        ToolParameter(
            name: "content",
            description: "Memory content payload",
            type: .string
        ),
        ToolParameter(
            name: "mode",
            description: "Write mode: replace or append (default: append)",
            type: .string,
            isRequired: false,
            defaultValue: .string("append")
        )
    ]

    private let store: any MemoryStore

    public init(store: any MemoryStore = FileMemoryStore.default()) {
        self.store = store
    }

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let scope = try parseScope(arguments: arguments)
        let mode = try parseMode(arguments: arguments)
        guard let content = arguments["content"]?.stringValue else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing content parameter")
        }
        let result = try await store.write(scope: scope, mode: mode, content: content)
        return .string("Memory updated scope=\(result.scope.rawValue) mode=\(result.mode.rawValue) bytes=\(result.bytes)")
    }
}

private func parseScope(arguments: [String: SendableValue]) throws -> MemoryScope {
    let raw = arguments["scope"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? MemoryScope.chat.rawValue
    guard let scope = MemoryScope(rawValue: raw) else {
        throw AgentError.invalidToolArguments(
            toolName: "memory",
            reason: "Invalid scope. Use chat or global."
        )
    }
    return scope
}

private func parseMode(arguments: [String: SendableValue]) throws -> MemoryWriteMode {
    let raw = arguments["mode"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? MemoryWriteMode.append.rawValue
    guard let mode = MemoryWriteMode(rawValue: raw) else {
        throw AgentError.invalidToolArguments(
            toolName: "write_memory",
            reason: "Invalid mode. Use append or replace."
        )
    }
    return mode
}

/// Tool for reading recent persisted conversation/task history.
public struct GetTaskHistoryTool: Tool, Sendable {
    public let name = "get_task_history"
    public let description = "Returns recent conversation and task-related history entries"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "limit", description: "Maximum number of entries to return (default: 20)", type: .int, isRequired: false, defaultValue: .int(20)),
        ToolParameter(name: "role", description: "Optional role filter: user, assistant, system, or tool", type: .string, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let requestedLimit = arguments["limit"]?.intValue ?? 20
        let clampedLimit = max(1, min(requestedLimit, 200))
        let roleFilter = arguments["role"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let session = FileBasedSession(groupFolder: resolveGroupFolderForTools())
        var items = try await session.getItems(limit: clampedLimit)

        if let roleFilter, !roleFilter.isEmpty {
            guard let role = MemoryMessage.Role(rawValue: roleFilter) else {
                throw AgentError.invalidToolArguments(
                    toolName: name,
                    reason: "Invalid role filter. Use user, assistant, system, or tool."
                )
            }
            items = items.filter { $0.role == role }
        }

        guard !items.isEmpty else {
            return .string("No task history yet.")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rendered = items.map { item in
            let content = item.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(formatter.string(from: item.timestamp)) [\(item.role.rawValue)] \(content)"
        }.joined(separator: "\n")

        return .string(rendered)
    }
}

/// Tool for exporting persisted chat history to a file.
public struct ExportChatTool: Tool, Sendable {
    public let name = "export_chat"
    public let description = "Exports persisted chat history to markdown or json"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "format", description: "Export format: markdown (default) or json", type: .string, isRequired: false, defaultValue: .string("markdown")),
        ToolParameter(name: "limit", description: "Maximum number of messages to export (optional)", type: .int, isRequired: false)
    ]

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let rawFormat = arguments["format"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "markdown"
        let limit = arguments["limit"]?.intValue

        let session = FileBasedSession(groupFolder: resolveGroupFolderForTools())
        let items = try await session.getItems(limit: limit)
        guard !items.isEmpty else {
            return .string("No chat history to export.")
        }

        let exportsDir = URL(fileURLWithPath: resolveBasePath()).appendingPathComponent(".nanoclaw/exports")
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let filename: String
        let payload: String
        switch rawFormat {
        case "markdown", "md":
            filename = "chat-\(ts).md"
            payload = renderMarkdown(items: items)
        case "json":
            filename = "chat-\(ts).json"
            payload = try renderJSON(items: items)
        default:
            throw AgentError.invalidToolArguments(toolName: name, reason: "Unsupported format. Use markdown or json.")
        }

        let fileURL = exportsDir.appendingPathComponent(filename)
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
        return .string("Exported chat to \(fileURL.path)\nMessages: \(items.count)\nFormat: \(rawFormat)")
    }

    private func renderMarkdown(items: [MemoryMessage]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = ["# Chat Export", ""]
        for item in items {
            lines.append("## \(item.role.rawValue.capitalized) · \(formatter.string(from: item.timestamp))")
            lines.append(item.content)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func renderJSON(items: [MemoryMessage]) throws -> String {
        struct ExportItem: Codable {
            let role: String
            let content: String
            let timestamp: String
            let metadata: [String: String]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let output = items.map { item in
            ExportItem(
                role: item.role.rawValue,
                content: item.content,
                timestamp: formatter.string(from: item.timestamp),
                metadata: item.metadata
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

/// Tool for delegated sub-agent reasoning on a focused prompt.
public struct SubAgentTool: Tool, Sendable {
    typealias ConfigLoaderClosure = @Sendable () async throws -> NanoClawConfig
    typealias ProviderFactoryClosure = @Sendable (NanoClawConfig) async throws -> any InferenceProvider

    public let name = "sub_agent"
    public let description = "Delegates a focused task to a lightweight sub-agent and returns its output"
    public let parameters: [ToolParameter] = [
        ToolParameter(name: "prompt", description: "Task prompt for the sub-agent", type: .string),
        ToolParameter(name: "context", description: "Optional extra context for delegation", type: .string, isRequired: false),
        ToolParameter(name: "temperature", description: "Optional generation temperature (0.0-2.0)", type: .string, isRequired: false)
    ]
    private let configLoader: ConfigLoaderClosure
    private let providerFactory: ProviderFactoryClosure

    public init() {
        self.configLoader = { try await Self.defaultConfigLoader() }
        self.providerFactory = { config in try await Self.defaultProviderFactory(config: config) }
    }

    init(
        configLoader: @escaping ConfigLoaderClosure,
        providerFactory: @escaping ProviderFactoryClosure
    ) {
        self.configLoader = configLoader
        self.providerFactory = providerFactory
    }

    public func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        guard let prompt = arguments["prompt"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty else {
            throw AgentError.invalidToolArguments(toolName: name, reason: "Missing prompt parameter")
        }

        let context = arguments["context"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configuredTemperature: Double = {
            if let raw = arguments["temperature"]?.stringValue, let value = Double(raw) {
                return value
            }
            if let value = arguments["temperature"]?.intValue {
                return Double(value)
            }
            return 0.4
        }()
        let temperature = max(0.0, min(configuredTemperature, 2.0))

        let config = try await configLoader()
        let provider = try await providerFactory(config)

        var delegatedPrompt = """
        You are a delegated sub-agent working on a focused task.
        Return only the best concise result for the requested task.

        Task:
        \(prompt)
        """
        if !context.isEmpty {
            delegatedPrompt += "\n\nAdditional context:\n\(context)"
        }

        let output = try await provider.generate(
            prompt: delegatedPrompt,
            options: InferenceOptions(temperature: temperature, maxTokens: config.maxTokens ?? 1200)
        )
        return .string(output)
    }

    private static func defaultConfigLoader() async throws -> NanoClawConfig {
        let configPath = "\(resolveBasePath())/.nanoclaw/config.json"
        return try await ConfigLoader.load(from: configPath)
    }

    private static func defaultProviderFactory(config: NanoClawConfig) async throws -> any InferenceProvider {
        try await SubAgentProviderRegistry.shared.provider(for: config)
    }
}

struct SubAgentProviderCacheKey: Hashable {
    let apiKey: String
    let provider: ModelProvider
    let model: ModelName
    let baseURL: String?
    let timeout: Int
    let requestsPerMinuteLimit: Int?
    let fallbackProvider: ModelProvider?
    let fallbackAPIKey: String?
    let fallbackModel: ModelName?
    let fallbackBaseURL: String?
    let fallbackRequestsPerMinuteLimit: Int?
}

actor SubAgentProviderRegistry {
    static let shared = SubAgentProviderRegistry()
    private var cache: [SubAgentProviderCacheKey: OpenAICompatibleProvider] = [:]

    func provider(for config: NanoClawConfig) async throws -> OpenAICompatibleProvider {
        let key = cacheKey(for: config)
        if let cached = cache[key] {
            return cached
        }

        let fallback = try await fallbackProvider(for: config, parentKey: key)
        let provider = OpenAICompatibleProvider(
            apiKey: config.apiKey,
            baseURL: config.effectiveBaseURL,
            model: config.model.rawValue,
            timeout: config.timeout,
            requestsPerMinuteLimit: config.requestsPerMinuteLimit,
            fallbackProvider: fallback
        )
        cache[key] = provider
        return provider
    }

    private func fallbackProvider(
        for config: NanoClawConfig,
        parentKey: SubAgentProviderCacheKey
    ) async throws -> OpenAICompatibleProvider? {
        guard let fallbackProvider = config.fallbackProvider,
              let fallbackAPIKey = config.fallbackAPIKey,
              !fallbackAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let nestedConfig = NanoClawConfig(
            apiKey: fallbackAPIKey,
            provider: fallbackProvider,
            model: config.fallbackModel ?? fallbackProvider.defaultModel,
            baseURL: config.fallbackBaseURL ?? fallbackProvider.defaultBaseURL,
            timeout: config.timeout,
            maxTokens: config.maxTokens,
            assistantName: config.assistantName,
            requestsPerMinuteLimit: config.fallbackRequestsPerMinuteLimit
        )
        let nestedKey = cacheKey(for: nestedConfig)
        if nestedKey == parentKey {
            return nil
        }
        return try await provider(for: nestedConfig)
    }

    private func cacheKey(for config: NanoClawConfig) -> SubAgentProviderCacheKey {
        SubAgentProviderCacheKey(
            apiKey: config.apiKey,
            provider: config.provider,
            model: config.model,
            baseURL: config.baseURL,
            timeout: config.timeout,
            requestsPerMinuteLimit: config.requestsPerMinuteLimit,
            fallbackProvider: config.fallbackProvider,
            fallbackAPIKey: config.fallbackAPIKey,
            fallbackModel: config.fallbackModel,
            fallbackBaseURL: config.fallbackBaseURL,
            fallbackRequestsPerMinuteLimit: config.fallbackRequestsPerMinuteLimit
        )
    }
}
