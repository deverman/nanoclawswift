import SwiftAgents
import Foundation

// MARK: - CLAUDEMemory

/// Memory implementation that loads and incorporates CLAUDE.md files into agent context.
///
/// `CLAUDEMemory` provides context management for NanoClaw agents by:
/// 1. Loading the group's CLAUDE.md file as system context
/// 2. Managing conversation history with the Session protocol
/// 3. Providing formatted context for agent prompts
///
/// The memory combines static context (from CLAUDE.md) with dynamic conversation history,
/// enabling agents to have persistent memory across interactions while respecting group-specific
/// instructions and preferences.
///
/// ## Thread Safety
/// As an actor, `CLAUDEMemory` provides automatic thread-safe access
/// to all memory data through Swift's actor isolation.
///
/// ## Example Usage
/// ```swift
/// // Create memory for a group
/// let memory = await CLAUDEMemory(groupFolder: "my-group")
///
/// // Add messages to conversation history
/// await memory.add(.user("Hello!"))
/// await memory.add(.assistant("Hi there!"))
///
/// // Get formatted context for a query
/// let context = await memory.context(for: "What did I ask?", tokenLimit: 4000)
/// ```
public actor CLAUDEMemory: Memory {
    // MARK: Public
    
    /// The group folder this memory is associated with.
    nonisolated public let groupFolder: String
    
    /// The session for persisting conversation history.
    public let session: any Session
    
    /// The loaded CLAUDE.md content (system context).
    public private(set) var claudeMdContent: String
    
    // MARK: - Memory Protocol Properties
    
    /// The number of messages currently stored (excluding CLAUDE.md system context).
    public var count: Int {
        get async {
            await session.itemCount
        }
    }
    
    /// Whether the memory contains no messages.
    public var isEmpty: Bool {
        get async {
            await session.isEmpty
        }
    }
    
    // MARK: - Initialization
    
    /// Creates a new CLAUDE memory for the given group folder.
    ///
    /// - Parameters:
    ///   - groupFolder: The group folder name (e.g., "my-group")
    ///   - session: Optional session for persistence (defaults to FileBasedSession)
    ///
    /// Automatically loads the CLAUDE.md file from the group folder if it exists.
    public init(groupFolder: String, session: (any Session)? = nil) async {
        self.groupFolder = groupFolder
        self.session = session ?? FileBasedSession(groupFolder: groupFolder)
        self.claudeMdContent = await Self.loadClaudeMd(groupFolder: groupFolder)
    }
    
    /// Creates a new CLAUDE memory with explicit parameters.
    ///
    /// - Parameters:
    ///   - groupFolder: The group folder name
    ///   - session: The session to use for conversation history
    ///   - claudeMdContent: The CLAUDE.md content (system context)
    public init(groupFolder: String, session: any Session, claudeMdContent: String) {
        self.groupFolder = groupFolder
        self.session = session
        self.claudeMdContent = claudeMdContent
    }
    
    // MARK: - Memory Protocol Methods
    
    /// Adds a message to memory.
    ///
    /// - Parameter message: The message to store.
    public func add(_ message: MemoryMessage) async {
        do {
            try await session.addItem(message)
        } catch {
            // Log error but don't throw - memory operations shouldn't break agent execution
            Log.agents.error("Failed to add message to memory: \(error.localizedDescription)")
        }
    }
    
    /// Retrieves context relevant to the query within token limits.
    ///
    /// The context includes:
    /// 1. CLAUDE.md system instructions (always included if present)
    /// 2. Recent conversation history (up to token limit)
    ///
    /// - Parameters:
    ///   - query: The query to find relevant context for (used for prioritization if needed)
    ///   - tokenLimit: Maximum tokens to include in the context
    /// - Returns: A formatted string containing relevant context.
    public func context(for query: String, tokenLimit: Int) async -> String {
        var parts: [String] = []
        var remainingTokens = tokenLimit
        
        // Always include CLAUDE.md content first (it's essential system context)
        if !claudeMdContent.isEmpty {
            let claudeMdTokens = estimateTokens(claudeMdContent)
            if claudeMdTokens < tokenLimit {
                parts.append("## Group Context (CLAUDE.md)\n\n\(claudeMdContent)")
                remainingTokens -= claudeMdTokens
            } else {
                // Truncate if too long
                let truncated = String(claudeMdContent.prefix(tokenLimit / 2))
                parts.append("## Group Context (CLAUDE.md) - Truncated\n\n\(truncated)...")
                remainingTokens -= tokenLimit / 2
            }
        }
        
        // Add conversation history if space permits
        if remainingTokens > 100 {  // Minimum threshold for useful context
            do {
                let history = try await session.getAllItems()
                let historyContext = formatMessagesForContext(history, tokenLimit: remainingTokens)
                if !historyContext.isEmpty {
                    parts.append("## Conversation History\n\n\(historyContext)")
                }
            } catch {
                Log.agents.error("Failed to retrieve conversation history: \(error.localizedDescription)")
            }
        }
        
        return parts.joined(separator: "\n\n---\n\n")
    }
    
    /// Returns all messages currently in memory.
    ///
    /// - Returns: Array of all stored messages, in chronological order.
    public func allMessages() async -> [MemoryMessage] {
        do {
            return try await session.getAllItems()
        } catch {
            Log.agents.error("Failed to retrieve all messages: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Removes all messages from memory.
    ///
    /// Note: This clears conversation history but preserves the CLAUDE.md content.
    public func clear() async {
        do {
            try await session.clearSession()
        } catch {
            Log.agents.error("Failed to clear memory: \(error.localizedDescription)")
        }
    }
    
    // MARK: - CLAUDE.md Management
    
    /// Reloads the CLAUDE.md file from disk.
    ///
    /// Call this if the CLAUDE.md file has been modified.
    public func reloadClaudeMd() async {
        claudeMdContent = await Self.loadClaudeMd(groupFolder: groupFolder)
    }
    
    /// Updates the CLAUDE.md content programmatically.
    ///
    /// - Parameter content: The new CLAUDE.md content.
    public func updateClaudeMd(content: String) {
        claudeMdContent = content
    }
    
    /// Saves the current CLAUDE.md content to disk.
    ///
    /// - Throws: `MemoryError.saveFailed` if writing fails.
    public func saveClaudeMd() async throws {
        let claudeMdPath = Self.resolveGroupPath(groupFolder: groupFolder) + "/CLAUDE.md"
        let url = URL(fileURLWithPath: claudeMdPath)
        
        do {
            try claudeMdContent.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw MemoryError.saveFailed(reason: "Failed to save CLAUDE.md: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Helpers
    
    /// Loads the CLAUDE.md file from the group folder.
    private static func loadClaudeMd(groupFolder: String) async -> String {
        let claudeMdPath = resolveGroupPath(groupFolder: groupFolder) + "/CLAUDE.md"
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: claudeMdPath) else {
            return ""
        }
        
        do {
            let url = URL(fileURLWithPath: claudeMdPath)
            let content = try String(contentsOf: url, encoding: .utf8)
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.agents.error("Failed to load CLAUDE.md for group '\(groupFolder)': \(error.localizedDescription)")
            return ""
        }
    }
    
    /// Estimates token count for a string.
    private func estimateTokens(_ text: String) -> Int {
        // Rough estimate: 1 token ≈ 4 characters for English text
        return text.count / 4
    }

    private static func resolveGroupPath(groupFolder: String) -> String {
        if groupFolder.hasPrefix("/") {
            return groupFolder
        }
        let basePath = ProcessInfo.processInfo.environment["NANOCLAW_BASE_PATH"] ?? "/workspace/group"
        let isolatedGroupMount = ProcessInfo.processInfo.environment["NANOCLAW_GROUP_ISOLATED_MOUNT"] == "1"
        if isolatedGroupMount {
            return basePath
        }
        return "\(basePath)/\(groupFolder)"
    }
}

// MARK: - MemoryError

/// Errors specific to CLAUDEMemory operations.
public enum MemoryError: Error {
    case saveFailed(reason: String)
    case loadFailed(reason: String)
}

// MARK: - Log Extension

/// Extension to provide Log.agents for CLAUDEMemory.
/// This is a simplified logger for the memory system.
private enum Log {
    static let agents = AgentsLogger()
    
    struct AgentsLogger {
        func error(_ message: String) {
            // In production, this would use the proper swift-log API
            // For now, we print to stderr to avoid interfering with JSON output
            let stderr = FileHandle.standardError
            let data = "[CLAUDEMemory Error] \(message)\n".data(using: .utf8)!
            stderr.write(data)
        }
    }
}
