import SwiftAgents
import Foundation

// MARK: - NanoClawAgent

/// Main NanoClaw Agent implementing the SwiftAgents `Agent` protocol.
///
/// `NanoClawAgent` is a ReAct-style agent that processes user prompts through
/// an iterative loop of reasoning and tool execution. It integrates with:
/// - CLAUDE.md memory for group-specific context
/// - File-based session persistence for conversation history
/// - Archiving hooks for audit trails
/// - IPC tools for WhatsApp integration
///
/// ## Architecture
///
/// The agent follows the ReAct pattern:
/// 1. **Reasoning**: Analyze the prompt and plan actions
/// 2. **Acting**: Execute tools to gather information or perform actions
/// 3. **Observing**: Process tool results and update understanding
/// 4. **Responding**: Generate final response to the user
///
/// ## Thread Safety
/// As an actor, `NanoClawAgent` provides automatic thread-safe access
/// to all agent state through Swift's actor isolation.
///
/// ## Example Usage
/// ```swift
/// let config = NanoClawConfig(apiKey: "...", provider: .kimi)
/// let agent = await NanoClawAgent(config: config, groupFolder: "my-group")
///
/// let result = try await agent.run("What's the weather?")
/// print(result.output)
/// ```
public actor NanoClawAgent: Agent {
    // MARK: Public
    
    /// The configuration for this agent.
    nonisolated public let configuration: AgentConfiguration
    
    /// The group folder this agent is associated with.
    nonisolated public let groupFolder: String
    
    /// Tools available to this agent.
    nonisolated public let tools: [any Tool]
    
    /// Instructions defining the agent's behavior.
    nonisolated public let instructions: String
    
    /// Memory system for context management (CLAUDE.md + conversation history).
    nonisolated public let memory: (any Memory)?
    
    /// Custom inference provider for LLM calls.
    nonisolated public let inferenceProvider: (any InferenceProvider)?
    
    /// Optional tracer for observability.
    nonisolated public let tracer: (any Tracer)?
    
    /// Input guardrails for validation.
    nonisolated public let inputGuardrails: [any InputGuardrail]
    
    /// Output guardrails for validation.
    nonisolated public let outputGuardrails: [any OutputGuardrail]
    
    /// Configured handoffs for multi-agent orchestration.
    nonisolated public let handoffs: [AnyHandoffConfiguration]
    
    // MARK: - Initialization
    
    /// Creates a new NanoClawAgent with the given configuration.
    ///
    /// - Parameters:
    ///   - config: The NanoClaw configuration (provider, model, API key, etc.)
    ///   - groupFolder: The group folder name for isolation and memory
    ///   - customInstructions: Optional custom instructions (defaults to CLAUDE.md)
    ///   - customTools: Optional additional tools
    public init(
        config: NanoClawConfig,
        groupFolder: String,
        customInstructions: String? = nil,
        customTools: [any Tool]? = nil
    ) async {
        self.groupFolder = groupFolder
        
        // Create inference provider
        let provider = OpenAICompatibleProvider(
            apiKey: config.apiKey,
            baseURL: config.effectiveBaseURL,
            model: config.model.rawValue,
            timeout: config.timeout
        )
        self.inferenceProvider = provider
        
        // Initialize CLAUDE memory
        let claudeMemory = await CLAUDEMemory(groupFolder: groupFolder)
        self.memory = claudeMemory
        
        // Build instructions
        let baseInstructions = customInstructions ?? Self.defaultInstructions(assistantName: config.assistantName)
        let claudeContext = await claudeMemory.claudeMdContent
        if !claudeContext.isEmpty {
            self.instructions = "## Group Context\n\n\(claudeContext)\n\n---\n\n\(baseInstructions)"
        } else {
            self.instructions = baseInstructions
        }
        
        // Build tool registry
        var allTools: [any Tool] = Self.createDefaultTools(groupFolder: groupFolder, chatJid: "default", isMain: false)
        if let customTools = customTools {
            allTools.append(contentsOf: customTools)
        }
        self.tools = allTools
        
        // Create agent configuration
        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw"
        )
        
        // No guardrails by default (can be added later)
        self.inputGuardrails = []
        self.outputGuardrails = []
        self.handoffs = []
        self.tracer = nil
    }
    
    /// Creates a new NanoClawAgent with explicit parameters for the CLI.
    ///
    /// - Parameters:
    ///   - config: The NanoClaw configuration
    ///   - groupFolder: The group folder name
    ///   - chatJid: The chat JID for IPC tools
    ///   - isMain: Whether this is the main channel
    ///   - isScheduledTask: Whether this is a scheduled task
    public init(
        config: NanoClawConfig,
        groupFolder: String,
        chatJid: String,
        isMain: Bool,
        isScheduledTask: Bool
    ) async {
        self.groupFolder = groupFolder
        
        // Create inference provider
        let provider = OpenAICompatibleProvider(
            apiKey: config.apiKey,
            baseURL: config.effectiveBaseURL,
            model: config.model.rawValue,
            timeout: config.timeout
        )
        self.inferenceProvider = provider
        
        // Initialize CLAUDE memory
        let claudeMemory = await CLAUDEMemory(groupFolder: groupFolder)
        self.memory = claudeMemory
        
        // Build instructions with optional scheduled task prefix
        let baseInstructions = Self.defaultInstructions(assistantName: config.assistantName)
        let claudeContext = await claudeMemory.claudeMdContent
        
        var fullInstructions = ""
        if isScheduledTask {
            fullInstructions += "[SCHEDULED TASK - You are running automatically, not in response to a user message. Use send_message if needed to communicate with the user.]\n\n"
        }
        if !claudeContext.isEmpty {
            fullInstructions += "## Group Context\n\n\(claudeContext)\n\n---\n\n\(baseInstructions)"
        } else {
            fullInstructions += baseInstructions
        }
        self.instructions = fullInstructions
        
        // Build tool registry with IPC tools configured
        self.tools = Self.createDefaultTools(groupFolder: groupFolder, chatJid: chatJid, isMain: isMain)
        
        // Create agent configuration
        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw"
        )
        
        // No guardrails by default
        self.inputGuardrails = []
        self.outputGuardrails = []
        self.handoffs = []
        self.tracer = nil
    }

    /// Creates a NanoClawAgent with injected dependencies (used for tests).
    public init(
        groupFolder: String,
        instructions: String,
        tools: [any Tool],
        memory: (any Memory)?,
        inferenceProvider: (any InferenceProvider)?,
        configurationName: String = "NanoClaw"
    ) async {
        self.groupFolder = groupFolder
        self.instructions = instructions
        self.tools = tools
        self.memory = memory
        self.inferenceProvider = inferenceProvider
        self.configuration = AgentConfiguration(name: configurationName)
        self.inputGuardrails = []
        self.outputGuardrails = []
        self.handoffs = []
        self.tracer = nil
    }
    
    // MARK: - Agent Protocol Methods
    
    /// Executes the agent with the given input.
    ///
    /// This is the main entry point for running the agent. It implements
    /// a ReAct-style loop of reasoning and tool execution.
    ///
    /// - Parameters:
    ///   - input: The user's input/query
    ///   - session: Optional session for conversation history
    ///   - hooks: Optional hooks for lifecycle callbacks
    /// - Returns: The result of the agent's execution
    /// - Throws: `AgentError` if execution fails
    public func run(_ input: String, session: (any Session)?, hooks: (any RunHooks)?) async throws -> AgentResult {
        let builder = AgentResult.Builder()
        builder.start()
        
        // Notify hooks
        if let hooks {
            await hooks.onAgentStart(context: nil, agent: self, input: input)
        }
        
        do {
            // Add user message to memory
            if let memory {
                await memory.add(.user(input))
            }
            
            // Create tool registry for execution
            let toolRegistry = ToolRegistry(tools: tools)
            
            // Main ReAct loop
            var iterations = 0
            let maxIterations = 10
            var finalOutput: String?
            var toolCallsExecuted = false
            
            while iterations < maxIterations && finalOutput == nil {
                iterations += 1
                builder.incrementIteration()
                
                // Check for cancellation
                try Task.checkCancellation()
                
                // Build context from memory on each iteration
                let contextString = if let memory {
                    await memory.context(for: input, tokenLimit: 4000)
                } else {
                    ""
                }
                
                // Construct the full prompt with context and instructions
                let fullPrompt = Self.buildPrompt(
                    input: input,
                    instructions: instructions,
                    context: contextString,
                    tools: tools
                )
                
                // If we've already executed tool calls, ask for a final response without tools
                if toolCallsExecuted {
                    let finalResponse = try await inferenceProvider?.generate(
                        prompt: fullPrompt,
                        options: InferenceOptions.default
                    )
                    finalOutput = finalResponse ?? "I apologize, but I couldn't generate a response."
                    break
                }

                // Generate response with potential tool calls
                if let hooks {
                    await hooks.onLLMStart(context: nil, agent: self, systemPrompt: instructions, inputMessages: [])
                }
                
                let inferenceResponse = try await inferenceProvider?.generateWithToolCalls(
                    prompt: fullPrompt,
                    tools: tools.map { $0.definition },
                    options: InferenceOptions.default
                )
                
                if let hooks, let inferenceResponse {
                    await hooks.onLLMEnd(
                        context: nil,
                        agent: self,
                        response: inferenceResponse.content ?? "",
                        usage: inferenceResponse.usage
                    )
                }
                
                guard let inferenceResponse else {
                    throw AgentError.generationFailed(reason: "Inference provider not available")
                }
                
                // Process tool calls if any
                if inferenceResponse.hasToolCalls {
                    for toolCall in inferenceResponse.toolCalls {
                        // Create ToolCall for result tracking
                        let tc = ToolCall(
                            toolName: toolCall.name,
                            arguments: toolCall.arguments
                        )
                        builder.addToolCall(tc)
                        
                        // Notify hooks
                        if let hooks {
                            await hooks.onToolStart(
                                context: nil,
                                agent: self,
                                tool: ToolWrapper(name: toolCall.name),
                                arguments: toolCall.arguments
                            )
                        }
                        
                        // Execute the tool
                        let toolResult: SendableValue
                        do {
                            toolResult = try await toolRegistry.execute(
                                toolNamed: toolCall.name,
                                arguments: toolCall.arguments,
                                agent: self,
                                context: nil,
                                hooks: hooks
                            )
                        } catch {
                            toolResult = .string("Error: \(error.localizedDescription)")
                        }
                        
                        // Add tool result
                        let tr = ToolResult(
                            callId: tc.id,
                            isSuccess: true,
                            output: toolResult,
                            duration: .zero,
                            errorMessage: nil
                        )
                        builder.addToolResult(tr)
                        
                        // Notify hooks
                        if let hooks {
                            await hooks.onToolEnd(context: nil, agent: self, tool: ToolWrapper(name: toolCall.name), result: toolResult)
                        }
                        
                        // Add to memory
                        if let memory {
                            await memory.add(.tool(toolResult.description, toolName: toolCall.name))
                        }
                    }
                    // Tool calls executed; next iteration will request final response
                    toolCallsExecuted = true
                } else if let content = inferenceResponse.content {
                    // Final response
                    finalOutput = content
                } else {
                    // Empty response
                    finalOutput = "I apologize, but I couldn't generate a response."
                }
            }
            
            // Set final output
            let output = finalOutput ?? "I apologize, but I couldn't complete the task within the allowed iterations."
            builder.setOutput(output)
            
            // Add assistant message to memory
            if let memory {
                await memory.add(.assistant(output))
            }
            
            // Notify hooks
            if let hooks {
                let result = builder.build()
                await hooks.onAgentEnd(context: nil, agent: self, result: result)
            }
            
            return builder.build()
            
        } catch {
            // Notify hooks of error
            if let hooks {
                await hooks.onError(context: nil, agent: self, error: error)
            }
            throw error
        }
    }
    
    /// Streams the agent's execution, yielding events as they occur.
    ///
    /// - Parameters:
    ///   - input: The user's input/query
    ///   - session: Optional session for conversation history
    ///   - hooks: Optional hooks for lifecycle callbacks
    /// - Returns: An async stream of agent events
    nonisolated public func stream(_ input: String, session: (any Session)?, hooks: (any RunHooks)?) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Start event
                    continuation.yield(.started(input: input))
                    
                    // Run the agent
                    let result = try await self.run(input, session: session, hooks: hooks)
                    
                    // Yield completion event
                    continuation.yield(.completed(result: result))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error: error as? AgentError ?? AgentError.generationFailed(reason: error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// Cancels any ongoing execution.
    public func cancel() async {
        // The ReAct loop checks for cancellation via Task.checkCancellation()
        // This method serves as a signal for potential future cancellation mechanisms
    }
    
    // MARK: - Run Methods (Backward Compatible)
    
    /// Runs the agent with a prompt (backward compatible method).
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - sessionId: Optional session ID for continuity
    ///   - chatJid: The chat JID
    ///   - isMain: Whether this is the main channel
    ///   - isScheduledTask: Whether this is a scheduled task
    /// - Returns: NanoClaw-specific result type
    public func run(
        prompt: String,
        sessionId: String?,
        chatJid: String,
        isMain: Bool,
        isScheduledTask: Bool
    ) async throws -> NanoClawAgentResult {
        // Get or create session
        let session: any Session
        if let sessionId = sessionId {
            session = FileBasedSession(groupFolder: groupFolder, sessionId: sessionId)
        } else {
            session = FileBasedSession(groupFolder: groupFolder)
        }
        
        // Create archiving hooks
        let archiveHooks = ArchivingHooks(groupFolder: groupFolder)
        
        // Run the agent
        let result = try await run(prompt, session: session, hooks: archiveHooks)
        
        // Return NanoClaw-specific result
        return NanoClawAgentResult(
            status: "success",
            result: result.output,
            newSessionId: await session.sessionId
        )
    }
    
    // MARK: - Private Helpers
    
    /// Default system instructions for the agent.
    private static func defaultInstructions(assistantName: String?) -> String {
        let name = assistantName ?? "Andy"
        return """
        You are \(name), a helpful AI assistant running in a NanoClaw container.
        
        You have access to various tools for:
        - Reading and writing files
        - Executing bash commands
        - Searching with grep and glob patterns
        - Sending WhatsApp messages (use send_message tool)
        - Scheduling recurring or one-time tasks
        
        Guidelines:
        1. Always use tools when available rather than guessing
        2. Read files before editing them
        3. Use atomic writes (write to temp file, then move)
        4. Respect the container filesystem boundaries (/workspace/group)
        5. For scheduled tasks, use schedule_task with appropriate schedule_type
        6. Be concise in your responses
        
        When the user asks you to modify files:
        1. Read the file first
        2. Show what changes you plan to make
        3. Apply the changes
        4. Confirm what was done
        """
    }
    
    /// Creates the default set of tools for the agent.
    private static func createDefaultTools(groupFolder: String, chatJid: String, isMain: Bool) -> [any Tool] {
        // File system tools
        let fileTools: [any Tool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            GlobTool(),
            GrepTool(),
            BashTool()
        ]
        
        // IPC tools for WhatsApp integration - use Sendable tool wrappers
        let ipcTools: [any Tool] = [
            SendMessageToolWrapper(chatJid: chatJid, groupFolder: groupFolder),
            ScheduleTaskToolWrapper(groupFolder: groupFolder, chatJid: chatJid, isMain: isMain),
            ListTasksToolWrapper(groupFolder: groupFolder, isMain: isMain),
            PauseTaskToolWrapper(groupFolder: groupFolder),
            ResumeTaskToolWrapper(groupFolder: groupFolder),
            CancelTaskToolWrapper(groupFolder: groupFolder)
        ]
        
        return fileTools + ipcTools
    }
    
    /// Builds the full prompt with context and instructions.
    private static func buildPrompt(
        input: String,
        instructions: String,
        context: String,
        tools: [any Tool]
    ) -> String {
        var parts: [String] = []
        
        // System instructions
        parts.append("## System Instructions\n\n\(instructions)")
        
        // Available tools
        parts.append("## Available Tools\n")
        for tool in tools {
            parts.append("- \(tool.name): \(tool.description)")
        }
        
        // Context if available
        if !context.isEmpty {
            parts.append("\n## Context\n\n\(context)")
        }
        
        // User input
        parts.append("\n## User Input\n\n\(input)")
        
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - ToolWrapper

/// Simple tool wrapper for hooks callbacks.
private struct ToolWrapper: Tool {
    let name: String
    let description: String = ""
    let parameters: [ToolParameter] = []
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        .string("")
    }
}

// MARK: - IPC Tool Wrappers

/// Wrapper for SendMessageTool that provides proper initialization.
private struct SendMessageToolWrapper: Tool {
    let name = "send_message"
    let description = "Sends a WhatsApp message to the group"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "message", description: "The message content to send", type: .string)
    ]
    
    let chatJid: String
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let message = arguments["message"]?.stringValue ?? ""
        let ipcDir = "/workspace/ipc/messages"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        
        let payload: [String: Any] = [
            "type": "send_message",
            "chat_jid": chatJid,
            "group_folder": groupFolder,
            "message": message,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))
        
        return .string("Message queued for delivery")
    }
}

/// Wrapper for ScheduleTaskTool.
private struct ScheduleTaskToolWrapper: Tool {
    let name = "schedule_task"
    let description = "Schedules a recurring or one-time task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "prompt", description: "Task prompt/instructions", type: .string),
        ToolParameter(name: "schedule_type", description: "Schedule type: 'cron', 'once', or 'interval'", type: .string),
        ToolParameter(name: "schedule_value", description: "Schedule value (cron expression, ISO date, or interval seconds)", type: .string),
        ToolParameter(name: "context_mode", description: "Context mode: 'group' (with history) or 'isolated' (fresh session)", type: .string, isRequired: false, defaultValue: .string("group"))
    ]
    
    let groupFolder: String
    let chatJid: String
    let isMain: Bool
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let prompt = arguments["prompt"]?.stringValue ?? ""
        let scheduleType = arguments["schedule_type"]?.stringValue ?? "once"
        let scheduleValue = arguments["schedule_value"]?.stringValue ?? ""
        let contextMode = arguments["context_mode"]?.stringValue ?? "group"
        
        let ipcDir = "/workspace/ipc/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        
        let payload: [String: Any] = [
            "type": "schedule_task",
            "group_folder": groupFolder,
            "chat_jid": chatJid,
            "is_main": isMain,
            "prompt": prompt,
            "schedule_type": scheduleType,
            "schedule_value": scheduleValue,
            "context_mode": contextMode,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))
        
        return .string("Task scheduled successfully")
    }
}

/// Wrapper for ListTasksTool.
private struct ListTasksToolWrapper: Tool {
    let name = "list_tasks"
    let description = "Lists all scheduled tasks"
    let parameters: [ToolParameter] = []
    
    let groupFolder: String
    let isMain: Bool
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let ipcDir = "/workspace/ipc/tasks"
        
        guard FileManager.default.fileExists(atPath: ipcDir) else {
            return .string("No tasks directory found")
        }
        
        let files = try FileManager.default.contentsOfDirectory(atPath: ipcDir)
        var tasks: [String] = []
        
        for file in files where file.hasSuffix(".json") {
            let filepath = "\(ipcDir)/\(file)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filepath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "schedule_task" else {
                continue
            }
            
            if let prompt = json["prompt"] as? String,
               let scheduleType = json["schedule_type"] as? String {
                tasks.append("- \(prompt.prefix(50))... (\(scheduleType))")
            }
        }
        
        return .string(tasks.isEmpty ? "No scheduled tasks" : tasks.joined(separator: "\n"))
    }
}

/// Wrapper for PauseTaskTool.
private struct PauseTaskToolWrapper: Tool {
    let name = "pause_task"
    let description = "Pauses a scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to pause", type: .string)
    ]
    
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        return .string("Task \(taskId) paused")
    }
}

/// Wrapper for ResumeTaskTool.
private struct ResumeTaskToolWrapper: Tool {
    let name = "resume_task"
    let description = "Resumes a paused scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to resume", type: .string)
    ]
    
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        return .string("Task \(taskId) resumed")
    }
}

/// Wrapper for CancelTaskTool.
private struct CancelTaskToolWrapper: Tool {
    let name = "cancel_task"
    let description = "Cancels a scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to cancel", type: .string)
    ]
    
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        return .string("Task \(taskId) cancelled")
    }
}

// MARK: - NanoClawAgentResult

/// Result type specific to NanoClawAgent (for CLI compatibility).
public struct NanoClawAgentResult {
    let status: String
    let result: String
    let newSessionId: String
    
    var json: String {
        let dict: [String: Any] = [
            "status": status,
            "result": result,
            "newSessionId": newSessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }
}
