import SwiftAgents
import Foundation

// MARK: - NanoClawAgent

/// Main NanoClaw agent facade backed by Swarm ToolCallingAgent.
public actor NanoClawAgent: Agent {
    // MARK: Public

    nonisolated public let configuration: AgentConfiguration
    nonisolated public let groupFolder: String
    nonisolated public let tools: [any Tool]
    nonisolated public let instructions: String
    nonisolated public let memory: (any Memory)?
    nonisolated public let inferenceProvider: (any InferenceProvider)?
    nonisolated public let tracer: (any Tracer)?
    nonisolated public let inputGuardrails: [any InputGuardrail]
    nonisolated public let outputGuardrails: [any OutputGuardrail]
    nonisolated public let handoffs: [AnyHandoffConfiguration]

    // MARK: Private

    private let baseToolAgent: ToolCallingAgent
    private let providerRoute: String

    // MARK: - Initialization

    public init(
        config: NanoClawConfig,
        groupFolder: String,
        customInstructions: String? = nil,
        customTools: [any Tool]? = nil
    ) async {
        self.groupFolder = groupFolder

        let provider = await Self.buildInferenceProvider(config: config)
        self.inferenceProvider = provider
        self.providerRoute = "\(config.provider.rawValue)/\(config.model.rawValue)"

        let claudeMemory = await CLAUDEMemory(groupFolder: groupFolder)
        self.memory = claudeMemory

        let baseInstructions = customInstructions ?? Self.defaultInstructions(assistantName: config.assistantName)
        let claudeContext = await claudeMemory.claudeMdContent
        if !claudeContext.isEmpty {
            self.instructions = "## Group Context\n\n\(claudeContext)\n\n---\n\n\(baseInstructions)"
        } else {
            self.instructions = baseInstructions
        }

        var allTools: [any Tool] = Self.createDefaultTools(groupFolder: groupFolder, chatJid: "default", isMain: false)
        if let customTools {
            allTools.append(contentsOf: customTools)
        }
        self.tools = allTools

        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw",
            maxIterations: 10,
            timeout: .seconds(config.timeout),
            temperature: 0.7,
            maxTokens: config.maxTokens,
            includeToolCallDetails: true,
            stopOnToolError: false,
            sessionHistoryLimit: 50,
            parallelToolCalls: false
        )

        self.tracer = nil
        self.handoffs = []
        self.inputGuardrails = Self.defaultInputGuardrails()
        self.outputGuardrails = Self.defaultOutputGuardrails()

        self.baseToolAgent = ToolCallingAgent(
            tools: self.tools,
            instructions: self.instructions,
            configuration: self.configuration,
            memory: self.memory,
            inferenceProvider: self.inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            handoffs: self.handoffs
        )
    }

    public init(
        config: NanoClawConfig,
        groupFolder: String,
        chatJid: String,
        isMain: Bool,
        isScheduledTask: Bool
    ) async {
        self.groupFolder = groupFolder

        let provider = await Self.buildInferenceProvider(config: config)
        self.inferenceProvider = provider
        self.providerRoute = "\(config.provider.rawValue)/\(config.model.rawValue)"

        let claudeMemory = await CLAUDEMemory(groupFolder: groupFolder)
        self.memory = claudeMemory

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

        self.tools = Self.createDefaultTools(groupFolder: groupFolder, chatJid: chatJid, isMain: isMain)

        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw",
            maxIterations: 10,
            timeout: .seconds(config.timeout),
            temperature: 0.7,
            maxTokens: config.maxTokens,
            includeToolCallDetails: true,
            stopOnToolError: false,
            sessionHistoryLimit: 50,
            parallelToolCalls: false
        )

        self.tracer = nil
        self.handoffs = []
        self.inputGuardrails = Self.defaultInputGuardrails()
        self.outputGuardrails = Self.defaultOutputGuardrails()

        self.baseToolAgent = ToolCallingAgent(
            tools: self.tools,
            instructions: self.instructions,
            configuration: self.configuration,
            memory: self.memory,
            inferenceProvider: self.inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            handoffs: self.handoffs
        )
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
        self.providerRoute = "custom"
        self.configuration = AgentConfiguration(name: configurationName)
        self.tracer = nil
        self.handoffs = []
        self.inputGuardrails = Self.defaultInputGuardrails()
        self.outputGuardrails = Self.defaultOutputGuardrails()

        self.baseToolAgent = ToolCallingAgent(
            tools: tools,
            instructions: instructions,
            configuration: self.configuration,
            memory: memory,
            inferenceProvider: inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            handoffs: self.handoffs
        )
    }

    // MARK: - Agent Protocol Methods

    public func run(_ input: String, session: (any Session)?, hooks: (any RunHooks)?) async throws -> AgentResult {
        let tracker = PerformanceTracker()
        await tracker.start()

        let traceName = "nanoclaw-agent-run"
        let traceGroupId: String? = if let session { session.sessionId } else { nil }

        do {
            let result = try await TraceContext.withTrace(
                traceName,
                groupId: traceGroupId,
                metadata: [
                    "groupFolder": .string(groupFolder),
                    "agentName": .string(configuration.name)
                ]
            ) {
                try await baseToolAgent.run(input, session: session, hooks: hooks)
            }

            let metrics = await tracker.finish()
            return Self.withMetrics(
                result: result,
                metrics: metrics,
                groupFolder: groupFolder,
                providerRoute: providerRoute,
                pseudoToolRejected: false
            )
        } catch let guardrailError as GuardrailError {
            let fallbackOutput = Self.guardrailFallbackMessage(for: guardrailError)
            if let hooks {
                let guardrailName: String
                let message: String
                switch guardrailError {
                case let .inputTripwireTriggered(name, msg, _):
                    guardrailName = name
                    message = msg ?? "Input blocked"
                case let .outputTripwireTriggered(name, _, msg, _):
                    guardrailName = name
                    message = msg ?? "Output blocked"
                case let .toolInputTripwireTriggered(name, _, msg, _):
                    guardrailName = name
                    message = msg ?? "Tool input blocked"
                case let .toolOutputTripwireTriggered(name, _, msg, _):
                    guardrailName = name
                    message = msg ?? "Tool output blocked"
                case let .executionFailed(name, err):
                    guardrailName = name
                    message = err
                }
                await hooks.onGuardrailTriggered(
                    context: nil,
                    guardrailName: guardrailName,
                    guardrailType: .output,
                    result: .tripwire(message: message)
                )
            }
            return Self.withMetrics(
                result: AgentResult(output: fallbackOutput, metadata: ["guardrail": .string(guardrailError.localizedDescription)]),
                metrics: await tracker.finish(),
                groupFolder: groupFolder,
                providerRoute: providerRoute,
                pseudoToolRejected: true
            )
        }
    }

    nonisolated public func stream(_ input: String, session: (any Session)?, hooks: (any RunHooks)?) -> AsyncThrowingStream<AgentEvent, Error> {
        baseToolAgent.stream(input, session: session, hooks: hooks)
    }

    public func cancel() async {
        await baseToolAgent.cancel()
    }

    // MARK: - Run Methods (Backward Compatible)

    public func run(
        prompt: String,
        sessionId: String?,
        chatJid: String,
        isMain: Bool,
        isScheduledTask: Bool
    ) async throws -> NanoClawAgentResult {
        let session: any Session
        if let sessionId {
            session = FileBasedSession(groupFolder: groupFolder, sessionId: sessionId)
        } else {
            session = FileBasedSession(groupFolder: groupFolder)
        }

        let archiveHooks = ArchivingHooks(groupFolder: groupFolder)
        let result = try await run(prompt, session: session, hooks: archiveHooks)

        return NanoClawAgentResult(
            status: "success",
            result: result.output,
            newSessionId: session.sessionId
        )
    }

    // MARK: - Private Helpers

    private static func buildInferenceProvider(config: NanoClawConfig) async -> any InferenceProvider {
        let provider = OpenAICompatibleProvider(
            apiKey: config.apiKey,
            baseURL: config.effectiveBaseURL,
            model: config.model.rawValue,
            timeout: config.timeout
        )

        let multiProvider = MultiProvider(defaultProvider: provider)
        try? await multiProvider.register(prefix: config.provider.rawValue, provider: provider)
        await multiProvider.setModel("\(config.provider.rawValue)/\(config.model.rawValue)")
        return multiProvider
    }

    private static func withMetrics(
        result: AgentResult,
        metrics: PerformanceMetrics,
        groupFolder: String,
        providerRoute: String,
        pseudoToolRejected: Bool
    ) -> AgentResult {
        var metadata = result.metadata
        metadata["nanoclaw.group_folder"] = .string(groupFolder)
        metadata["nanoclaw.provider_route"] = .string(providerRoute)
        metadata["nanoclaw.tool_call_count"] = .int(result.toolCalls.count)
        metadata["nanoclaw.pseudo_tool_rejected"] = .bool(pseudoToolRejected)
        metadata["metrics.totalDurationMs"] = .double(Double(metrics.totalDuration.components.seconds * 1000))
        metadata["metrics.toolCount"] = .int(metrics.toolCount)
        metadata["metrics.usedParallelExecution"] = .bool(metrics.usedParallelExecution)

        return AgentResult(
            output: result.output,
            toolCalls: result.toolCalls,
            toolResults: result.toolResults,
            iterationCount: result.iterationCount,
            duration: result.duration,
            tokenUsage: result.tokenUsage,
            metadata: metadata
        )
    }

    private static func guardrailFallbackMessage(for error: GuardrailError) -> String {
        switch error {
        case let .inputTripwireTriggered(name, message, _):
            if name == "nanoclaw_tool_syntax_input_guardrail" {
                return "I cannot execute raw tool-block syntax from user input. Please ask in plain language and I will call tools using structured tool calls."
            }
            return message ?? "Input blocked by policy."
        case let .outputTripwireTriggered(name, _, message, _):
            if name == "nanoclaw_tool_syntax_output_guardrail" {
                return "I could not execute that action because the model did not issue a valid structured tool call. Please retry your request."
            }
            return message ?? "Output blocked by policy."
        case let .toolInputTripwireTriggered(_, _, message, _),
             let .toolOutputTripwireTriggered(_, _, message, _):
            return message ?? "Tool request blocked by policy."
        case .executionFailed:
            return "A safety policy check failed unexpectedly. Please retry."
        }
    }

    private static func defaultInputGuardrails() -> [any InputGuardrail] {
        let guardrail = ClosureInputGuardrail(name: "nanoclaw_tool_syntax_input_guardrail") { input, _ in
            if containsPseudoToolSyntax(input) {
                return .tripwire(
                    message: "Raw tool block syntax is not accepted in input.",
                    metadata: ["reason": .string("pseudo_tool_syntax")]
                )
            }
            return .passed()
        }
        return [guardrail]
    }

    private static func defaultOutputGuardrails() -> [any OutputGuardrail] {
        let guardrail = ClosureOutputGuardrail(name: "nanoclaw_tool_syntax_output_guardrail") { output, _, _ in
            if containsPseudoToolSyntax(output) {
                return .tripwire(
                    message: "Model output contained raw tool block syntax instead of structured tool calls.",
                    metadata: ["reason": .string("pseudo_tool_syntax")]
                )
            }
            return .passed()
        }
        return [guardrail]
    }

    private static func containsPseudoToolSyntax(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```tool") {
            return true
        }
        let pattern = #"(schedule_task|list_tasks|cancel_task|pause_task|resume_task|send_message|web_search|web_fetch)\s*:\s*\d+\s*>\s*\{"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private static func defaultInstructions(assistantName: String?) -> String {
        let name = assistantName ?? "Andy"
        return """
        You are \(name), a helpful AI assistant running in a NanoClaw container.

        You have access to various tools for:
        - Reading and writing files
        - Executing bash commands
        - Searching with grep and glob patterns
        - Fetching/searching the web through host broker tools
        - Managing group-scoped web allowlist policy
        - Sending WhatsApp messages (use send_message tool)
        - Scheduling recurring or one-time tasks

        Guidelines:
        1. Always use tools when available rather than guessing
        2. Read files before editing them
        3. Use atomic writes (write to temp file, then move)
        4. Respect the container filesystem boundaries (/workspace/group)
        5. For scheduled tasks, use schedule_task with appropriate schedule_type
        6. Be concise in your responses
        7. Never output raw tool-call code blocks like ```tool ...``` in your final answer
        8. After using tools, respond with plain language and include the tool result directly

        When the user asks you to modify files:
        1. Read the file first
        2. Show what changes you plan to make
        3. Apply the changes
        4. Confirm what was done
        """
    }

    private static func createDefaultTools(groupFolder: String, chatJid: String, isMain: Bool) -> [any Tool] {
        let fileTools: [any Tool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            GlobTool(),
            GrepTool(),
            WebFetchTool(),
            WebSearchTool(),
            WebPolicyAddDomainTool(),
            WebPolicyRemoveDomainTool(),
            WebPolicyListTool(),
            BashTool()
        ]

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

private func resolveIPCBasePath() -> String {
    ProcessInfo.processInfo.environment["NANOCLAW_IPC_BASE_PATH"] ?? "/workspace/ipc"
}

// MARK: - IPC Tool Wrappers

/// Wrapper for SendMessageTool that provides proper initialization.
struct SendMessageToolWrapper: Tool {
    let name = "send_message"
    let description = "Sends a WhatsApp message to the group"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "message", description: "The message content to send", type: .string)
    ]
    
    let chatJid: String
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let message = arguments["message"]?.stringValue ?? ""
        let ipcDir = "\(resolveIPCBasePath())/messages"
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
struct ScheduleTaskToolWrapper: Tool {
    let name = "schedule_task"
    let description = "Schedules a recurring or one-time task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "prompt", description: "Task prompt/instructions", type: .string, isRequired: false),
        ToolParameter(name: "description", description: "Alias for prompt", type: .string, isRequired: false),
        ToolParameter(name: "schedule_type", description: "Schedule type: 'cron', 'once', 'interval', or 'recurring' (alias for daily cron)", type: .string),
        ToolParameter(name: "schedule_value", description: "Schedule value (cron expression, ISO date, or interval milliseconds)", type: .string, isRequired: false),
        ToolParameter(name: "time", description: "Alias for recurring daily time in HH:mm (e.g. 08:00)", type: .string, isRequired: false),
        ToolParameter(name: "context_mode", description: "Context mode: 'group' (with history) or 'isolated' (fresh session)", type: .string, isRequired: false, defaultValue: .string("group"))
    ]
    
    let groupFolder: String
    let chatJid: String
    let isMain: Bool

    private func resolvedGroupFolder() -> String {
        if let envGroup = ProcessInfo.processInfo.environment["NANOCLAW_GROUP_FOLDER"],
           !envGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envGroup
        }
        return groupFolder
    }

    private func normalizeSchedule(
        scheduleType rawType: String,
        scheduleValue rawValue: String,
        time: String
    ) -> (type: String, value: String)? {
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dailyTime = time.trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case "cron", "once", "interval":
            if !value.isEmpty {
                return (type, value)
            }
            if type == "cron", let cron = hhmmToDailyCron(dailyTime) {
                return ("cron", cron)
            }
            return nil
        case "recurring":
            if !value.isEmpty {
                return ("cron", value)
            }
            if let cron = hhmmToDailyCron(dailyTime) {
                return ("cron", cron)
            }
            // Safe default: 08:00 local daily
            return ("cron", "0 8 * * *")
        default:
            // If caller omitted schedule_type but provided a time, assume daily recurring.
            if let cron = hhmmToDailyCron(dailyTime) {
                return ("cron", cron)
            }
            return nil
        }
    }

    private func hhmmToDailyCron(_ hhmm: String) -> String? {
        let comps = hhmm.split(separator: ":")
        guard comps.count == 2,
              let hour = Int(comps[0]),
              let minute = Int(comps[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return "\(minute) \(hour) * * *"
    }
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let prompt = (arguments["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (arguments["description"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt = prompt.isEmpty ? description : prompt
        if resolvedPrompt.isEmpty {
            return .string("Error: missing task prompt/description")
        }

        let scheduleTypeRaw = arguments["schedule_type"]?.stringValue ?? ""
        let scheduleValueRaw = arguments["schedule_value"]?.stringValue ?? ""
        let timeRaw = arguments["time"]?.stringValue ?? ""
        guard let normalized = normalizeSchedule(
            scheduleType: scheduleTypeRaw,
            scheduleValue: scheduleValueRaw,
            time: timeRaw
        ) else {
            return .string("Error: invalid schedule arguments. Use schedule_type + schedule_value, or recurring + time (HH:mm).")
        }

        let contextMode = arguments["context_mode"]?.stringValue ?? "group"
        
        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        
        let payload: [String: Any] = [
            "type": "schedule_task",
            "group_folder": resolvedGroupFolder(),
            "chat_jid": chatJid,
            "is_main": isMain,
            "prompt": resolvedPrompt,
            "schedule_type": normalized.type,
            "schedule_value": normalized.value,
            "context_mode": contextMode,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))
        
        return .string("Task scheduled successfully (\(normalized.type): \(normalized.value))")
    }
}

/// Wrapper for ListTasksTool.
struct ListTasksToolWrapper: Tool {
    let name = "list_tasks"
    let description = "Lists all scheduled tasks"
    let parameters: [ToolParameter] = []
    
    let groupFolder: String
    let isMain: Bool
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let snapshotPath = "\(resolveIPCBasePath())/current_tasks.json"
        guard FileManager.default.fileExists(atPath: snapshotPath) else {
            return .string("No scheduled tasks")
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .string("No scheduled tasks")
        }

        let filtered = items.filter { item in
            guard let status = item["status"] as? String else { return false }
            guard status == "active" || status == "paused" else { return false }
            if isMain { return true }
            return (item["groupFolder"] as? String) == groupFolder
        }

        if filtered.isEmpty {
            return .string("No scheduled tasks")
        }

        let lines = filtered.map { item -> String in
            let id = (item["id"] as? String) ?? "unknown"
            let prompt = (item["prompt"] as? String) ?? "(no prompt)"
            let scheduleType = (item["schedule_type"] as? String) ?? "unknown"
            let scheduleValue = (item["schedule_value"] as? String) ?? "unknown"
            let status = (item["status"] as? String) ?? "unknown"
            let nextRun = (item["next_run"] as? String) ?? "n/a"
            return "- [\(status)] \(id): \(prompt.prefix(80))... (\(scheduleType): \(scheduleValue), next: \(nextRun))"
        }

        return .string(lines.joined(separator: "\n"))
    }
}

/// Wrapper for PauseTaskTool.
struct PauseTaskToolWrapper: Tool {
    let name = "pause_task"
    let description = "Pauses a scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to pause", type: .string)
    ]
    
    let groupFolder: String

    private func resolvedGroupFolder() -> String {
        if let envGroup = ProcessInfo.processInfo.environment["NANOCLAW_GROUP_FOLDER"],
           !envGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envGroup
        }
        return groupFolder
    }
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "pause_task",
            "task_id": taskId,
            "group_folder": resolvedGroupFolder(),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        return .string("Task \(taskId) pause requested")
    }
}

/// Wrapper for ResumeTaskTool.
struct ResumeTaskToolWrapper: Tool {
    let name = "resume_task"
    let description = "Resumes a paused scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to resume", type: .string)
    ]
    
    let groupFolder: String

    private func resolvedGroupFolder() -> String {
        if let envGroup = ProcessInfo.processInfo.environment["NANOCLAW_GROUP_FOLDER"],
           !envGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envGroup
        }
        return groupFolder
    }
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "resume_task",
            "task_id": taskId,
            "group_folder": resolvedGroupFolder(),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        return .string("Task \(taskId) resume requested")
    }
}

/// Wrapper for CancelTaskTool.
struct CancelTaskToolWrapper: Tool {
    let name = "cancel_task"
    let description = "Cancels a scheduled task"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "task_id", description: "Task ID to cancel", type: .string)
    ]
    
    let groupFolder: String

    private func resolvedGroupFolder() -> String {
        if let envGroup = ProcessInfo.processInfo.environment["NANOCLAW_GROUP_FOLDER"],
           !envGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envGroup
        }
        return groupFolder
    }
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let taskId = arguments["task_id"]?.stringValue ?? ""
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "cancel_task",
            "task_id": taskId,
            "group_folder": resolvedGroupFolder(),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        return .string("Task \(taskId) cancel requested")
    }
}

// MARK: - NanoClawAgentResult

/// Result type specific to NanoClawAgent (for CLI compatibility).
public struct NanoClawAgentResult: Sendable {
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
