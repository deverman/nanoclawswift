import SwiftAgents
import Foundation

// MARK: - ArchivingHooks

/// RunHooks implementation that archives conversations to JSON files.
///
/// `ArchivingHooks` captures agent execution events and archives them to the group folder's
/// `.nanoclaw/archive/` directory. Each conversation is saved as a timestamped JSON file
/// with full metadata including messages, tool calls, and timing information.
///
/// This enables:
/// - Audit trails of all agent interactions
/// - Conversation replay and analysis
/// - Debugging and troubleshooting
/// - Compliance and logging requirements
///
/// ## Thread Safety
/// As an actor, `ArchivingHooks` provides automatic thread-safe access
/// to archive operations through Swift's actor isolation.
///
/// ## Example Usage
/// ```swift
/// let hooks = ArchivingHooks(groupFolder: "my-group")
///
/// let agent = ReActAgent(
///     tools: [...],
///     instructions: "...",
///     runHooks: [hooks]
/// )
///
/// // All agent executions will be archived automatically
/// let result = try await agent.run("Hello!")
/// ```
public actor ArchivingHooks: RunHooks {
    // MARK: Public
    
    /// The group folder where archives are stored.
    nonisolated public let groupFolder: String
    
    /// The directory where archive files are stored.
    nonisolated public let archiveDirectory: String
    
    /// Maximum number of archive files to keep (older files are deleted).
    public var maxArchives: Int
    
    /// Whether to include full message content in archives (may be large).
    public var includeFullContent: Bool
    
    // MARK: - Initialization
    
    /// Creates a new archiving hooks instance for the given group folder.
    ///
    /// - Parameters:
    ///   - groupFolder: The group folder name (e.g., "my-group")
    ///   - maxArchives: Maximum number of archives to keep (default: 100)
    ///   - includeFullContent: Whether to include full content (default: true)
    ///
    /// Archives are stored at `/workspace/group/{groupFolder}/.nanoclaw/archive/`
    public init(
        groupFolder: String,
        maxArchives: Int = 100,
        includeFullContent: Bool = true
    ) {
        self.groupFolder = groupFolder
        self.archiveDirectory = "/workspace/group/\(groupFolder)/.nanoclaw/archive"
        self.maxArchives = maxArchives
        self.includeFullContent = includeFullContent
        
        // Ensure archive directory exists
        Task {
            await ensureArchiveDirectoryExists()
        }
    }
    
    // MARK: - RunHooks Implementation
    
    /// Called when an agent begins execution.
    public func onAgentStart(context: AgentContext?, agent: any Agent, input: String) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .agentStart,
            agentName: agent.configuration.name,
            input: includeFullContent ? input : String(input.prefix(200)) + "...",
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when an agent completes execution successfully.
    public func onAgentEnd(context: AgentContext?, agent: any Agent, result: AgentResult) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .agentEnd,
            agentName: agent.configuration.name,
            output: includeFullContent ? result.output : String(result.output.prefix(200)) + "...",
            iterations: result.iterationCount,
            toolCount: result.toolCalls.count,
            duration: result.duration.description,
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
        
        // After agent ends, write the complete archive file
        await writeArchiveFile(contextId: context?.executionId.uuidString)
    }
    
    /// Called when an agent encounters an error during execution.
    public func onError(context: AgentContext?, agent: any Agent, error: Error) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .error,
            agentName: agent.configuration.name,
            errorMessage: error.localizedDescription,
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when an agent hands off execution to another agent.
    public func onHandoff(context: AgentContext?, fromAgent: any Agent, toAgent: any Agent) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .handoff,
            agentName: fromAgent.configuration.name,
            handoffTo: toAgent.configuration.name,
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when a tool execution begins.
    public func onToolStart(context: AgentContext?, agent: any Agent, tool: any Tool, arguments: [String: SendableValue]) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .toolStart,
            agentName: agent.configuration.name,
            toolName: tool.name,
            arguments: arguments.mapValues { $0.description },
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when a tool execution completes successfully.
    public func onToolEnd(context: AgentContext?, agent: any Agent, tool: any Tool, result: SendableValue) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .toolEnd,
            agentName: agent.configuration.name,
            toolName: tool.name,
            result: includeFullContent ? result.description : String(result.description.prefix(200)) + "...",
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when an LLM inference begins.
    public func onLLMStart(context: AgentContext?, agent: any Agent, systemPrompt: String?, inputMessages: [MemoryMessage]) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .llmStart,
            agentName: agent.configuration.name,
            messageCount: inputMessages.count,
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when an LLM inference completes.
    public func onLLMEnd(context: AgentContext?, agent: any Agent, response: String, usage: InferenceResponse.TokenUsage?) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .llmEnd,
            agentName: agent.configuration.name,
            output: includeFullContent ? response : String(response.prefix(200)) + "...",
            tokenUsage: usage.map { "\($0.inputTokens) in / \($0.outputTokens) out" },
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    /// Called when a guardrail is triggered during execution.
    public func onGuardrailTriggered(context: AgentContext?, guardrailName: String, guardrailType: GuardrailType, result: GuardrailResult) async {
        let archiveEntry = ArchiveEntry(
            timestamp: Date(),
            event: .guardrail,
            agentName: context.flatMap { _ in "agent" } ?? "unknown", // Context doesn't expose agent name directly
            guardrailName: guardrailName,
            guardrailType: guardrailType.rawValue,
            guardrailMessage: result.message,
            contextId: context?.executionId.uuidString
        )
        await appendEntry(archiveEntry)
    }
    
    // MARK: - Archive Management
    
    /// Lists all archived conversation files.
    ///
    /// - Returns: Array of archive file paths, sorted by date (newest first).
    public func listArchives() async -> [String] {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: archiveDirectory) else {
            return []
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(atPath: archiveDirectory)
            let jsonFiles = files
                .filter { $0.hasSuffix(".json") }
                .map { "\(archiveDirectory)/\($0)" }
                .sorted(by: { $0 > $1 }) // Sort newest first (timestamp in filename)
            return jsonFiles
        } catch {
            return []
        }
    }
    
    /// Reads a specific archive file.
    ///
    /// - Parameter path: Full path to the archive file.
    /// - Returns: The archived conversation data, or nil if not found/invalid.
    func readArchive(path: String) async -> ArchivedConversation? {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ArchivedConversation.self, from: data)
        } catch {
            return nil
        }
    }
    
    /// Deletes old archives, keeping only the most recent `maxArchives`.
    public func cleanupOldArchives() async {
        let archives = await listArchives()
        
        guard archives.count > maxArchives else {
            return
        }
        
        let filesToDelete = archives[maxArchives...]
        let fileManager = FileManager.default
        
        for file in filesToDelete {
            do {
                try fileManager.removeItem(atPath: file)
            } catch {
                // Log but continue
                print("[ArchivingHooks] Failed to delete old archive: \(file)")
            }
        }
    }
    
    // MARK: Private
    
    /// Current in-memory entries for the active conversation.
    private var currentEntries: [ArchiveEntry] = []
    
    /// File manager for operations.
    private let fileManager = FileManager.default
    
    /// Ensures the archive directory exists.
    private func ensureArchiveDirectoryExists() async {
        if !fileManager.fileExists(atPath: archiveDirectory) {
            do {
                try fileManager.createDirectory(
                    atPath: archiveDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                print("[ArchivingHooks] Failed to create archive directory: \(error)")
            }
        }
    }
    
    /// Appends an entry to the current conversation buffer.
    private func appendEntry(_ entry: ArchiveEntry) async {
        currentEntries.append(entry)
    }
    
    /// Writes the current conversation to a timestamped archive file.
    private func writeArchiveFile(contextId: String?) async {
        guard !currentEntries.isEmpty else {
            return
        }
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "\(timestamp)_\(contextId ?? UUID().uuidString).json"
        let filepath = "\(archiveDirectory)/\(filename)"
        
        let conversation = ArchivedConversation(
            id: contextId ?? UUID().uuidString,
            timestamp: Date(),
            groupFolder: groupFolder,
            entries: currentEntries
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(conversation)
            
            try data.write(to: URL(fileURLWithPath: filepath))
            
            // Set restrictive permissions
            try setSecurePermissions(path: filepath)
            
            // Clear the buffer
            currentEntries.removeAll()
            
            // Cleanup old archives
            await cleanupOldArchives()
            
        } catch {
            print("[ArchivingHooks] Failed to write archive: \(error)")
        }
    }
    
    /// Sets file permissions to 600 (owner read/write only).
    private func setSecurePermissions(path: String) throws {
        #if os(macOS) || os(Linux)
        let permissions: mode_t = 0o600
        let result = chmod(path, permissions)
        
        if result != 0 {
            throw ArchivingError.permissionError(path: path, error: String(cString: strerror(errno)))
        }
        #endif
    }
}

// MARK: - Archive Types

/// A single entry in the archive.
struct ArchiveEntry: Codable, Sendable {
    let timestamp: Date
    let event: ArchiveEvent
    let agentName: String?
    let input: String?
    let output: String?
    let errorMessage: String?
    let handoffTo: String?
    let toolName: String?
    let arguments: [String: String]?
    let result: String?
    let iterations: Int?
    let toolCount: Int?
    let duration: String?
    let messageCount: Int?
    let tokenUsage: String?
    let guardrailName: String?
    let guardrailType: String?
    let guardrailMessage: String?
    let contextId: String?
    
    init(
        timestamp: Date,
        event: ArchiveEvent,
        agentName: String? = nil,
        input: String? = nil,
        output: String? = nil,
        errorMessage: String? = nil,
        handoffTo: String? = nil,
        toolName: String? = nil,
        arguments: [String: String]? = nil,
        result: String? = nil,
        iterations: Int? = nil,
        toolCount: Int? = nil,
        duration: String? = nil,
        messageCount: Int? = nil,
        tokenUsage: String? = nil,
        guardrailName: String? = nil,
        guardrailType: String? = nil,
        guardrailMessage: String? = nil,
        contextId: String? = nil
    ) {
        self.timestamp = timestamp
        self.event = event
        self.agentName = agentName
        self.input = input
        self.output = output
        self.errorMessage = errorMessage
        self.handoffTo = handoffTo
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.iterations = iterations
        self.toolCount = toolCount
        self.duration = duration
        self.messageCount = messageCount
        self.tokenUsage = tokenUsage
        self.guardrailName = guardrailName
        self.guardrailType = guardrailType
        self.guardrailMessage = guardrailMessage
        self.contextId = contextId
    }
}

/// Types of events that can be archived.
enum ArchiveEvent: String, Codable, Sendable {
    case agentStart
    case agentEnd
    case error
    case handoff
    case toolStart
    case toolEnd
    case llmStart
    case llmEnd
    case guardrail
}

/// A complete archived conversation.
struct ArchivedConversation: Codable, Sendable {
    let id: String
    let timestamp: Date
    let groupFolder: String
    let entries: [ArchiveEntry]
}

// MARK: - ArchivingError

/// Errors specific to archiving operations.
public enum ArchivingError: Error {
    case permissionError(path: String, error: String)
    case writeError(path: String, error: String)
}
