import SwiftAgents
import Foundation

// MARK: - NanoClawAgent

public enum ExecutionRoute: String, Sendable {
    case toolCalling = "tool_calling"
    case planAndExecute = "plan_and_execute"
}

struct ExplicitToolInvocation: Sendable {
    let toolName: String
    let arguments: [String: SendableValue]
}

private struct MCPPaginationState: Sendable {
    let serverID: String
    let baseArgs: [String]
    let nextCursor: String
}

private struct MCPPaginationRecoveryOutcome: Sendable {
    let rawOutput: String
    let toolCall: ToolCall
    let toolResult: ToolResult
    let duration: Duration
}

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
    nonisolated public let mcpStartupDiagnostics: [String]

    // MARK: Private

    private let baseToolAgent: ToolCallingAgent
    private let basePlanAndExecuteAgent: PlanAndExecuteAgent
    private let providerRoute: String
    private let mcpRuntimeExecutor: MCPRuntimeExecutor?
    private var lastMCPHostCLIPagination: MCPPaginationState? = nil
    private var lastMCPHostCLIPaginationExhaustedNotice: String? = nil

    nonisolated static let swarmIterationCeiling: Int = 60
    nonisolated static let memoryContextTokenBudget: Int = 600
    nonisolated static let skillContextHeader: String = "[SKILLS CONTEXT - apply these active skill instructions when relevant.]"

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
        let persistentMemoryContext = await Self.loadPersistentMemoryContext(
            tokenBudget: Self.memoryContextTokenBudget
        )
        let mcpBootstrap = await MCPRuntimeBootstrapLoader.load()
        self.mcpRuntimeExecutor = mcpBootstrap.executor
        self.mcpStartupDiagnostics = mcpBootstrap.diagnostics

        var composedInstructions = Self.composeInstructions(
            baseInstructions: baseInstructions,
            groupContext: claudeContext,
            persistentMemoryContext: persistentMemoryContext,
            isScheduledTask: false
        )
        if !mcpBootstrap.diagnostics.isEmpty {
            composedInstructions += "\n\n## MCP Runtime Diagnostics\n\(mcpBootstrap.diagnostics.joined(separator: "\n"))"
        }
        self.instructions = composedInstructions

        var allTools: [any Tool] = Self.createDefaultTools(
            groupFolder: groupFolder,
            chatJid: "default",
            isMain: false,
            mcpStatus: mcpBootstrap.status
        )
        allTools.append(contentsOf: mcpBootstrap.tools.map { $0 as any Tool })
        if let customTools {
            allTools.append(contentsOf: customTools)
        }
        self.tools = allTools

        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw",
            maxIterations: Self.swarmIterationCeiling,
            timeout: .seconds(config.timeout),
            temperature: 0.7,
            maxTokens: config.maxTokens,
            includeToolCallDetails: true,
            stopOnToolError: false,
            sessionHistoryLimit: 12,
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

        self.basePlanAndExecuteAgent = PlanAndExecuteAgent(
            tools: self.tools,
            instructions: self.instructions,
            configuration: self.configuration,
            memory: self.memory,
            inferenceProvider: self.inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            maxReplanAttempts: 3,
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
        let persistentMemoryContext = await Self.loadPersistentMemoryContext(
            tokenBudget: Self.memoryContextTokenBudget
        )
        let mcpBootstrap = await MCPRuntimeBootstrapLoader.load()
        self.mcpRuntimeExecutor = mcpBootstrap.executor
        self.mcpStartupDiagnostics = mcpBootstrap.diagnostics

        var composedInstructions = Self.composeInstructions(
            baseInstructions: baseInstructions,
            groupContext: claudeContext,
            persistentMemoryContext: persistentMemoryContext,
            isScheduledTask: isScheduledTask
        )
        if !mcpBootstrap.diagnostics.isEmpty {
            composedInstructions += "\n\n## MCP Runtime Diagnostics\n\(mcpBootstrap.diagnostics.joined(separator: "\n"))"
        }
        self.instructions = composedInstructions

        var allTools = Self.createDefaultTools(
            groupFolder: groupFolder,
            chatJid: chatJid,
            isMain: isMain,
            mcpStatus: mcpBootstrap.status
        )
        allTools.append(contentsOf: mcpBootstrap.tools.map { $0 as any Tool })
        self.tools = allTools

        self.configuration = AgentConfiguration(
            name: config.assistantName ?? "NanoClaw",
            maxIterations: Self.swarmIterationCeiling,
            timeout: .seconds(config.timeout),
            temperature: 0.7,
            maxTokens: config.maxTokens,
            includeToolCallDetails: true,
            stopOnToolError: false,
            sessionHistoryLimit: 12,
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

        self.basePlanAndExecuteAgent = PlanAndExecuteAgent(
            tools: self.tools,
            instructions: self.instructions,
            configuration: self.configuration,
            memory: self.memory,
            inferenceProvider: self.inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            maxReplanAttempts: 3,
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
        self.mcpRuntimeExecutor = nil
        self.mcpStartupDiagnostics = []
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

        self.basePlanAndExecuteAgent = PlanAndExecuteAgent(
            tools: tools,
            instructions: instructions,
            configuration: self.configuration,
            memory: memory,
            inferenceProvider: inferenceProvider,
            tracer: self.tracer,
            inputGuardrails: self.inputGuardrails,
            outputGuardrails: self.outputGuardrails,
            maxReplanAttempts: 3,
            handoffs: self.handoffs
        )
    }

    // MARK: - Agent Protocol Methods

    nonisolated public static func executionRoute(for input: String) -> ExecutionRoute {
        let normalized = input.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let markers = [
            "first",
            "then",
            "finally",
            "step by step",
            "step-by-step",
            "multi-step",
            "plan",
            "compare",
            "and then",
            "didn't get",
            "did not get",
            "didnt get",
            "missed",
            "resend",
            "morning report",
            "send it"
        ]
        let signalCount = markers.reduce(into: 0) { partial, marker in
            if normalized.contains(marker) {
                partial += 1
            }
        }
        return signalCount >= 2 ? .planAndExecute : .toolCalling
    }

    nonisolated static func isMissedMorningReportPrompt(_ input: String) -> Bool {
        let normalized = input.lowercased().replacingOccurrences(of: "’", with: "'")
        let hasMissedSignal = normalized.contains("didn't get")
            || normalized.contains("did not get")
            || normalized.contains("didnt get")
            || normalized.contains("missed")
        let hasReportSignal = normalized.contains("morning") && normalized.contains("report")
        let hasSendSignal = normalized.contains("send it")
            || normalized.contains("can you send")
            || normalized.contains("send now")
        return hasMissedSignal && hasReportSignal && hasSendSignal
    }

    nonisolated private static func explicitTaskActionWithoutID(
        for input: String,
        availableToolNames: Set<String>
    ) -> TaskActionVerb? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let checks: [(TaskActionVerb, String)] = [
            (.resume, #"^\s*(?:please\s+)?resume\s+task\s*[.!?]?\s*$"#),
            (.pause, #"^\s*(?:please\s+)?pause\s+task\s*[.!?]?\s*$"#),
            (.cancel, #"^\s*(?:please\s+)?cancel\s+task\s*[.!?]?\s*$"#)
        ]
        for (action, pattern) in checks {
            let toolName = "\(action.rawValue)_task"
            guard availableToolNames.contains(toolName) else { continue }
            if containsMatch(in: text, pattern: pattern) {
                return action
            }
        }
        return nil
    }

    nonisolated static func summarizeMorningReportTaskState(from listTasksOutput: String) -> String {
        let trimmed = listTasksOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "No scheduled tasks" {
            return "I couldn’t find a scheduled morning report task. If you want, I can set one up now."
        }

        let lines = trimmed.split(separator: "\n").map(String.init)
        if let idIndex = lines.firstIndex(where: { $0.lowercased().contains("task id:") }) {
            let idLine = lines[idIndex]
            let statusLine = lines[idIndex...]
                .first(where: { $0.lowercased().contains("status:") }) ?? "Status: Unknown"
            let selected = "\(idLine)\n\(statusLine)"
            let lowerStatus = statusLine.lowercased()
            if lowerStatus.contains("active") {
                return "Your morning report task is active:\n\(selected)\nIf you want today’s report right now, say: \"Send my morning Apple report now.\""
            }
            if lowerStatus.contains("paused") {
                return "Your morning report task is paused:\n\(selected)\nSay: \"Please resume task <task-id>\" and I can also send one now."
            }
            return "Here’s the closest scheduled report task I found:\n\(selected)"
        }

        let candidate = lines.first { line in
            let lower = line.lowercased()
            return lower.contains("morning") || lower.contains("apple") || lower.contains("report")
        } ?? lines.first

        guard let selected = candidate else {
            return "I couldn’t find a scheduled morning report task. If you want, I can set one up now."
        }

        if selected.lowercased().contains("[active]") {
            return "Your morning report task is active:\n\(selected)\nIf you want today’s report right now, say: \"Send my morning Apple report now.\""
        }

        if selected.lowercased().contains("[paused]") {
            return "Your morning report task is paused:\n\(selected)\nSay: \"Please resume task <task-id>\" and I can also send one now."
        }

        return "Here’s the closest scheduled report task I found:\n\(selected)"
    }

    public func run(_ input: String, session: (any Session)?, hooks: (any RunHooks)?) async throws -> AgentResult {
        let tracker = PerformanceTracker()
        await tracker.start()
        let skillContext = SkillsContextComposer.compose(for: input)
        let effectiveInput: String
        let runSkillMetadata: [String: SendableValue]
        if let skillContext {
            effectiveInput = "\(Self.skillContextHeader)\n\n\(skillContext.instructionBlock)\n\n---\n\n\(input)"
            runSkillMetadata = Self.skillMetadata(from: skillContext)
        } else {
            effectiveInput = input
            runSkillMetadata = [
                "nanoclaw.skills.injected_count": .int(0),
                "nanoclaw.skills.injected_ids": .array([]),
                "nanoclaw.skills.injected_names": .array([]),
                "nanoclaw.skills.truncated": .bool(false),
                "nanoclaw.skills.resolver_applied": .bool(false),
                "nanoclaw.skills.resolver_selected": .bool(false)
            ]
        }

        let traceName = "nanoclaw-agent-run"
        let traceGroupId: String? = if let session { session.sessionId } else { nil }

        if let deterministic = try await deterministicMissedMorningReportResponse(
            for: input,
            session: session,
            hooks: hooks
        ) {
            let metrics = await tracker.finish()
            return Self.withMetrics(
                result: deterministic,
                metrics: metrics,
                groupFolder: groupFolder,
                providerRoute: providerRoute,
                pseudoToolRejected: false,
                executionRoute: .toolCalling,
                attemptCount: 1,
                retryPolicy: Self.retryPolicy(for: .toolCalling),
                loopBudget: Self.loopBudgetPolicy(
                    for: .toolCalling,
                    timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
                ),
                extraMetadata: runSkillMetadata
            )
        }

        let availableToolNames = Set(tools.map(\.name))
        if let deterministicAction = try await deterministicTaskActionWithoutIDResponse(
            for: input,
            availableToolNames: availableToolNames
        ) {
            let metrics = await tracker.finish()
            return Self.withMetrics(
                result: deterministicAction,
                metrics: metrics,
                groupFolder: groupFolder,
                providerRoute: providerRoute,
                pseudoToolRejected: false,
                executionRoute: .toolCalling,
                attemptCount: 1,
                retryPolicy: Self.retryPolicy(for: .toolCalling),
                loopBudget: Self.loopBudgetPolicy(
                    for: .toolCalling,
                    timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
                ),
                extraMetadata: runSkillMetadata
            )
        }

        if Self.isPaginationContinuationPrompt(input),
           availableToolNames.contains("mcp_host_cli"),
           lastMCPHostCLIPagination == nil {
            let message = lastMCPHostCLIPaginationExhaustedNotice
                ?? "No paginated MCP result is active yet. Run a paginated MCP command first, then say \"show more\"."
            let metrics = await tracker.finish()
            return Self.withMetrics(
                result: AgentResult(
                    output: message,
                    iterationCount: 1,
                    metadata: ["nanoclaw.explicit_tool_mode": .bool(true)]
                ),
                metrics: metrics,
                groupFolder: groupFolder,
                providerRoute: providerRoute,
                pseudoToolRejected: false,
                executionRoute: .toolCalling,
                attemptCount: 1,
                retryPolicy: Self.retryPolicy(for: .toolCalling),
                loopBudget: Self.loopBudgetPolicy(
                    for: .toolCalling,
                    timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
                ),
                extraMetadata: runSkillMetadata
            )
        }

        if let explicit = paginationContinuationInvocation(
            for: input,
            availableToolNames: availableToolNames
        ) ?? Self.explicitToolInvocation(for: input, availableToolNames: availableToolNames),
           let tool = tools.first(where: { $0.name == explicit.toolName }) {
            let callStart = ContinuousClock.now
            let toolCall = ToolCall(toolName: explicit.toolName, arguments: explicit.arguments)
            do {
                let output = try await tool.execute(arguments: explicit.arguments)
                let duration = ContinuousClock.now - callStart
                var rawOutput = output.stringValue ?? output.description
                var explicitDuration = duration
                var explicitToolCalls: [ToolCall] = [toolCall]
                var explicitToolResults: [ToolResult] = [
                    .success(callId: toolCall.id, output: output, duration: duration)
                ]
                var recoveredCursorPagination = false

                if let recovery = try await recoverMCPPaginationOutputIfNeeded(
                    toolName: explicit.toolName,
                    tool: tool,
                    arguments: explicit.arguments,
                    rawOutput: rawOutput
                ) {
                    rawOutput = recovery.rawOutput
                    explicitDuration += recovery.duration
                    explicitToolCalls.append(recovery.toolCall)
                    explicitToolResults.append(recovery.toolResult)
                    recoveredCursorPagination = true
                }

                await updateMCPPaginationState(
                    toolName: explicit.toolName,
                    arguments: explicit.arguments,
                    rawOutput: rawOutput
                )
                let renderedOutput = Self.renderExplicitToolOutput(toolName: explicit.toolName, rawOutput: rawOutput)
                let hintedOutput = Self.appendPaginationHintIfNeeded(
                    toolName: explicit.toolName,
                    rawOutput: rawOutput,
                    renderedOutput: renderedOutput
                )
                let userFacingOutput = Self.overrideTerminalPaginationOutputIfNeeded(
                    toolName: explicit.toolName,
                    arguments: explicit.arguments,
                    rawOutput: rawOutput,
                    renderedOutput: hintedOutput
                )
                var metadata: [String: SendableValue] = ["nanoclaw.explicit_tool_mode": .bool(true)]
                if recoveredCursorPagination {
                    metadata["nanoclaw.mcp_pagination_recovered"] = .bool(true)
                }
                let directResult = AgentResult(
                    output: userFacingOutput,
                    toolCalls: explicitToolCalls,
                    toolResults: explicitToolResults,
                    iterationCount: 1,
                    duration: explicitDuration,
                    metadata: metadata
                )
                let metrics = await tracker.finish()
                return Self.withMetrics(
                    result: directResult,
                    metrics: metrics,
                    groupFolder: groupFolder,
                    providerRoute: providerRoute,
                    pseudoToolRejected: false,
                    executionRoute: .toolCalling,
                    attemptCount: 1,
                    retryPolicy: Self.retryPolicy(for: .toolCalling),
                    loopBudget: Self.loopBudgetPolicy(
                        for: .toolCalling,
                        timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
                    ),
                    extraMetadata: runSkillMetadata
                )
            } catch {
                await clearMCPPaginationStateIfNeeded(for: explicit.toolName)
                let duration = ContinuousClock.now - callStart
                let message = (error as? AgentError)?.localizedDescription ?? error.localizedDescription
                let directResult = AgentResult(
                    output: message,
                    toolCalls: [toolCall],
                    toolResults: [.failure(callId: toolCall.id, error: message, duration: duration)],
                    iterationCount: 1,
                    duration: duration,
                    metadata: ["nanoclaw.explicit_tool_mode": .bool(true)]
                )
                let metrics = await tracker.finish()
                return Self.withMetrics(
                    result: directResult,
                    metrics: metrics,
                    groupFolder: groupFolder,
                    providerRoute: providerRoute,
                    pseudoToolRejected: false,
                    executionRoute: .toolCalling,
                    attemptCount: 1,
                    retryPolicy: Self.retryPolicy(for: .toolCalling),
                    loopBudget: Self.loopBudgetPolicy(
                        for: .toolCalling,
                        timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
                    ),
                    extraMetadata: runSkillMetadata
                )
            }
        }

        let route = Self.executionRoute(for: input)
        let loopBudget = Self.loopBudgetPolicy(
            for: route,
            timeoutSeconds: Self.timeoutSeconds(from: configuration.timeout)
        )
        let retryPolicy = Self.retryPolicy(for: route)

        var attempt = 1
        var didRetryEmptyVisibleOutput = false
        while true {
            do {
                let result = try await TraceContext.withTrace(
                    traceName,
                    groupId: traceGroupId,
                    metadata: [
                        "groupFolder": .string(groupFolder),
                        "agentName": .string(configuration.name),
                        "executionRoute": .string(route.rawValue),
                        "attempt": .int(attempt)
                    ]
                ) {
                    switch route {
                    case .toolCalling:
                        return try await baseToolAgent.run(effectiveInput, session: session, hooks: hooks)
                    case .planAndExecute:
                        return try await basePlanAndExecuteAgent.run(effectiveInput, session: session, hooks: hooks)
                    }
                }

                let normalizedResult = Self.renderUserFacingMCPOutputIfNeeded(result)

                try Self.enforceLoopBudget(normalizedResult, budget: loopBudget)
                if Self.sanitizeUserFacingOutput(normalizedResult.output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty {
                    if !didRetryEmptyVisibleOutput {
                        didRetryEmptyVisibleOutput = true
                        attempt += 1
                        try await Task.sleep(for: .milliseconds(Self.emptyVisibleReplyRetryDelayMs))
                        continue
                    }

                    let fallback = AgentResult(
                        output: "I completed internal steps but couldn't produce a visible reply. Please retry with a shorter, more specific request.",
                        toolCalls: normalizedResult.toolCalls,
                        toolResults: normalizedResult.toolResults,
                        iterationCount: normalizedResult.iterationCount,
                        duration: normalizedResult.duration,
                        metadata: normalizedResult.metadata
                    )
                    let metrics = await tracker.finish()
                    return Self.withMetrics(
                        result: fallback,
                        metrics: metrics,
                        groupFolder: groupFolder,
                        providerRoute: providerRoute,
                        pseudoToolRejected: false,
                        executionRoute: route,
                        attemptCount: attempt,
                        retryPolicy: retryPolicy,
                        loopBudget: loopBudget,
                        stopReason: "empty_visible_output",
                        extraMetadata: runSkillMetadata
                    )
                }

                try await Self.compactSessionIfNeeded(session: session)
                await updateMCPPaginationState(from: normalizedResult)

                let metrics = await tracker.finish()
                return Self.withMetrics(
                    result: normalizedResult,
                    metrics: metrics,
                    groupFolder: groupFolder,
                    providerRoute: providerRoute,
                    pseudoToolRejected: false,
                    executionRoute: route,
                    attemptCount: attempt,
                    retryPolicy: retryPolicy,
                    loopBudget: loopBudget,
                    stopReason: "completed",
                    extraMetadata: runSkillMetadata
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
                    pseudoToolRejected: true,
                    executionRoute: route,
                    attemptCount: attempt,
                    retryPolicy: retryPolicy,
                    loopBudget: loopBudget,
                    stopReason: "guardrail",
                    extraMetadata: runSkillMetadata
                )
            } catch {
                switch Self.retryDecision(for: error, attempt: attempt, policy: retryPolicy) {
                case .retry(let delay):
                    attempt += 1
                    try await Task.sleep(for: delay)
                case .fail:
                    if let friendlyResult = Self.userFacingFailureResult(
                        from: error,
                        route: route,
                        loopBudget: loopBudget
                    ) {
                        let metrics = await tracker.finish()
                        return Self.withMetrics(
                            result: friendlyResult.result,
                            metrics: metrics,
                            groupFolder: groupFolder,
                            providerRoute: providerRoute,
                            pseudoToolRejected: false,
                            executionRoute: route,
                            attemptCount: attempt,
                            retryPolicy: retryPolicy,
                            loopBudget: loopBudget,
                            stopReason: friendlyResult.stopReason,
                            extraMetadata: runSkillMetadata
                        )
                    }
                    throw error
                }
            }
        }
    }

    private func paginationContinuationInvocation(
        for input: String,
        availableToolNames: Set<String>
    ) -> ExplicitToolInvocation? {
        guard availableToolNames.contains("mcp_host_cli"),
              Self.isPaginationContinuationPrompt(input),
              let pagination = lastMCPHostCLIPagination else {
            return nil
        }

        var args = pagination.baseArgs
        if let overrideLimit = Self.paginationContinuationLimitOverride(input) {
            args = Self.replacingOrAppendingFlag(
                named: "--limit",
                value: String(overrideLimit),
                in: args
            )
        }
        args.append("--cursor")
        args.append(pagination.nextCursor)
        return ExplicitToolInvocation(
            toolName: "mcp_host_cli",
            arguments: [
                "server_id": .string(pagination.serverID),
                "args": .array(args.map { .string($0) })
            ]
        )
    }

    private func updateMCPPaginationState(
        toolName: String,
        arguments: [String: SendableValue],
        rawOutput: String
    ) async {
        guard toolName == "mcp_host_cli" else { return }
        guard let serverID = arguments["server_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty else {
            lastMCPHostCLIPagination = nil
            lastMCPHostCLIPaginationExhaustedNotice = nil
            return
        }
        let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let isCursorRequest = Self.containsCursorArgument(in: args)
        let itemCount = Self.extractItemsCount(fromRawOutput: rawOutput) ?? -1
        if isCursorRequest, itemCount == 0 {
            lastMCPHostCLIPagination = nil
            lastMCPHostCLIPaginationExhaustedNotice = "No additional items were returned for the next page. You’ve reached the end (or the cursor is stale)."
            return
        }

        guard let nextCursor = Self.extractNextCursor(fromRawOutput: rawOutput) else {
            lastMCPHostCLIPagination = nil
            lastMCPHostCLIPaginationExhaustedNotice = nil
            return
        }

        let baseArgs = Self.removingCursorArguments(from: args)
        lastMCPHostCLIPagination = MCPPaginationState(
            serverID: serverID,
            baseArgs: baseArgs,
            nextCursor: nextCursor
        )
        lastMCPHostCLIPaginationExhaustedNotice = nil
    }

    private func updateMCPPaginationState(from result: AgentResult) async {
        guard let call = result.toolCalls.last(where: { $0.toolName == "mcp_host_cli" }),
              let toolResult = result.toolResults.last(where: { $0.callId == call.id && $0.isSuccess }) else {
            return
        }
        let rawOutput = toolResult.output.stringValue ?? toolResult.output.description
        await updateMCPPaginationState(
            toolName: call.toolName,
            arguments: call.arguments,
            rawOutput: rawOutput
        )
    }

    private func clearMCPPaginationStateIfNeeded(for toolName: String) async {
        guard toolName == "mcp_host_cli" else { return }
        lastMCPHostCLIPagination = nil
        lastMCPHostCLIPaginationExhaustedNotice = nil
    }

    private func recoverMCPPaginationOutputIfNeeded(
        toolName: String,
        tool: any Tool,
        arguments: [String: SendableValue],
        rawOutput: String
    ) async throws -> MCPPaginationRecoveryOutcome? {
        guard toolName == "mcp_host_cli",
              let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue),
              Self.containsCursorArgument(in: args),
              let itemCount = Self.extractItemsCount(fromRawOutput: rawOutput),
              itemCount == 0,
              let serverID = arguments["server_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty,
              let cursorRaw = Self.flagValue(named: "--cursor", in: args),
              let cursor = Int(cursorRaw),
              cursor >= 0,
              let limitRaw = Self.flagValue(named: "--limit", in: args),
              let limit = Int(limitRaw),
              limit > 0 else {
            return nil
        }

        let expandedLimit = cursor + limit
        guard expandedLimit > limit else { return nil }

        let baseArgs = Self.removingCursorArguments(from: args)
        let expandedArgs = Self.replacingOrAppendingFlag(
            named: "--limit",
            value: String(expandedLimit),
            in: baseArgs
        )
        let fallbackArguments: [String: SendableValue] = [
            "server_id": .string(serverID),
            "args": .array(expandedArgs.map { .string($0) })
        ]
        let fallbackCall = ToolCall(toolName: "mcp_host_cli", arguments: fallbackArguments)
        let fallbackStart = ContinuousClock.now
        let fallbackOutput = try await tool.execute(arguments: fallbackArguments)
        let fallbackDuration = ContinuousClock.now - fallbackStart
        let fallbackRawOutput = fallbackOutput.stringValue ?? fallbackOutput.description

        guard let recoveredRawOutput = Self.recoveredPaginationRawOutput(
            fromSupersetRawOutput: fallbackRawOutput,
            offset: cursor,
            pageSize: limit,
            expandedLimit: expandedLimit
        ) else {
            return nil
        }

        return MCPPaginationRecoveryOutcome(
            rawOutput: recoveredRawOutput,
            toolCall: fallbackCall,
            toolResult: .success(callId: fallbackCall.id, output: fallbackOutput, duration: fallbackDuration),
            duration: fallbackDuration
        )
    }

    private func deterministicMissedMorningReportResponse(
        for input: String,
        session: (any Session)?,
        hooks: (any RunHooks)?
    ) async throws -> AgentResult? {
        guard Self.isMissedMorningReportPrompt(input),
              let listTasksTool = tools.first(where: { $0.name == "list_tasks" }) else {
            return nil
        }

        let start = ContinuousClock.now
        let toolCall = ToolCall(toolName: "list_tasks", arguments: [:])
        let output = try await listTasksTool.execute(arguments: [:])
        let duration = ContinuousClock.now - start
        let listText = output.stringValue ?? output.description

        if let task = morningReportTaskCandidate(),
           !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let scheduledResult = try await run(task.prompt, session: session, hooks: hooks)
            let statusNote: String
            if task.status.lowercased() == "paused" {
                statusNote = "I found your paused morning report task (\(task.id)) and ran it once now without changing its schedule status."
            } else {
                statusNote = "I found your morning report task (\(task.id)) and ran it now."
            }

            let mergedToolCalls = [toolCall] + scheduledResult.toolCalls
            let mergedToolResults = [ToolResult.success(callId: toolCall.id, output: output, duration: duration)] + scheduledResult.toolResults
            var mergedMetadata = scheduledResult.metadata
            mergedMetadata["nanoclaw.explicit_tool_mode"] = .bool(true)
            mergedMetadata["nanoclaw.missed_report_fast_path"] = .bool(true)
            mergedMetadata["nanoclaw.missed_report_task_id"] = .string(task.id)

            return AgentResult(
                output: "\(statusNote)\n\n\(scheduledResult.output)",
                toolCalls: mergedToolCalls,
                toolResults: mergedToolResults,
                iterationCount: max(1, scheduledResult.iterationCount + 1),
                duration: duration + scheduledResult.duration,
                metadata: mergedMetadata
            )
        }

        let summary = Self.summarizeMorningReportTaskState(from: listText)

        return AgentResult(
            output: summary,
            toolCalls: [toolCall],
            toolResults: [.success(callId: toolCall.id, output: output, duration: duration)],
            iterationCount: 1,
            duration: duration,
            metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.missed_report_fast_path": .bool(true)]
        )
    }

    private func deterministicTaskActionWithoutIDResponse(
        for input: String,
        availableToolNames: Set<String>
    ) async throws -> AgentResult? {
        guard let action = Self.explicitTaskActionWithoutID(for: input, availableToolNames: availableToolNames) else {
            return nil
        }

        let toolName = "\(action.rawValue)_task"
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            return nil
        }

        let allTasks = loadSnapshotTasks()
            .filter { $0.groupFolder == groupFolder }
            .filter { task in
                let status = task.status.lowercased()
                return status == "active" || status == "paused"
            }

        let candidates = allTasks.filter { task in
            switch action {
            case .resume:
                return task.status.lowercased() == "paused"
            case .pause:
                return task.status.lowercased() == "active"
            case .cancel:
                return true
            }
        }

        let start = ContinuousClock.now

        guard !candidates.isEmpty else {
            let duration = ContinuousClock.now - start
            let oppositeCandidates = allTasks.filter { task in
                switch action {
                case .resume:
                    return task.status.lowercased() == "active"
                case .pause:
                    return task.status.lowercased() == "paused"
                case .cancel:
                    return false
                }
            }

            if oppositeCandidates.count == 1, let onlyTask = oppositeCandidates.first {
                let desiredState = action == .resume ? "active" : "paused"
                return AgentResult(
                    output: taskAlreadyInStateMessage(desiredState: desiredState, task: onlyTask),
                    iterationCount: 1,
                    duration: duration,
                    metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.task_action_without_id": .bool(true)]
                )
            }

            let qualifier: String
            switch action {
            case .resume:
                qualifier = "paused"
            case .pause:
                qualifier = "active"
            case .cancel:
                qualifier = "scheduled"
            }
            return AgentResult(
                output: "I couldn’t find any \(qualifier) tasks to \(action.rawValue). Try \"Please list my tasks\" first.",
                iterationCount: 1,
                duration: duration,
                metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.task_action_without_id": .bool(true)]
            )
        }

        if candidates.count > 1 {
            let sorted = candidates.sorted { $0.id < $1.id }
            let lines = sorted.map(taskLineSummary).joined(separator: "\n- ")
            let output = """
I found multiple tasks to \(action.rawValue). Which one should I \(action.rawValue)?
- \(lines)
Reply with the exact task ID, for example: "Please \(action.rawValue) task \(sorted[0].id)".
"""
            let duration = ContinuousClock.now - start
            return AgentResult(
                output: output,
                iterationCount: 1,
                duration: duration,
                metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.task_action_without_id": .bool(true)]
            )
        }

        let task = candidates[0]
        let arguments: [String: SendableValue] = ["task_id": .string(task.id)]
        let toolCall = ToolCall(toolName: toolName, arguments: arguments)
        do {
            let output = try await tool.execute(arguments: arguments)
            let duration = ContinuousClock.now - start
            return AgentResult(
                output: output.stringValue ?? output.description,
                toolCalls: [toolCall],
                toolResults: [.success(callId: toolCall.id, output: output, duration: duration)],
                iterationCount: 1,
                duration: duration,
                metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.task_action_without_id": .bool(true)]
            )
        } catch {
            let duration = ContinuousClock.now - start
            let message = (error as? AgentError)?.localizedDescription ?? error.localizedDescription
            return AgentResult(
                output: message,
                toolCalls: [toolCall],
                toolResults: [.failure(callId: toolCall.id, error: message, duration: duration)],
                iterationCount: 1,
                duration: duration,
                metadata: ["nanoclaw.explicit_tool_mode": .bool(true), "nanoclaw.task_action_without_id": .bool(true)]
            )
        }
    }

    private func morningReportTaskCandidate() -> SnapshotTask? {
        let tasks = loadSnapshotTasks().filter { task in
            task.groupFolder == groupFolder
        }
        guard !tasks.isEmpty else {
            return nil
        }

        let runnable = tasks.filter { task in
            let status = task.status.lowercased()
            return status == "active" || status == "paused"
        }
        let candidates = runnable.isEmpty ? tasks : runnable
        guard !candidates.isEmpty else {
            return nil
        }

        func score(_ task: SnapshotTask) -> Int {
            let prompt = task.prompt.lowercased()
            var value = 0
            if prompt.contains("morning") { value += 3 }
            if prompt.contains("report") { value += 3 }
            if prompt.contains("apple") { value += 2 }
            if prompt.contains("news") { value += 1 }
            return value
        }

        return candidates.max { lhs, rhs in
            let leftScore = score(lhs)
            let rightScore = score(rhs)
            if leftScore == rightScore {
                return lhs.id > rhs.id
            }
            return leftScore < rightScore
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
            toolCallsCount: result.toolCalls.count,
            newSessionId: session.sessionId
        )
    }

    // MARK: - Private Helpers

    private static func buildInferenceProvider(config: NanoClawConfig) async -> any InferenceProvider {
        let fallbackProvider: OpenAICompatibleProvider? = {
            guard let fallback = config.fallbackProvider,
                  let fallbackAPIKey = config.fallbackAPIKey,
                  !fallbackAPIKey.isEmpty else {
                return nil
            }
            let fallbackModel = (config.fallbackModel ?? fallback.defaultModel).rawValue
            let fallbackBaseURL = config.fallbackBaseURL ?? fallback.defaultBaseURL
            return OpenAICompatibleProvider(
                apiKey: fallbackAPIKey,
                baseURL: fallbackBaseURL,
                model: fallbackModel,
                timeout: config.timeout,
                requestsPerMinuteLimit: config.fallbackRequestsPerMinuteLimit
            )
        }()

        let provider = OpenAICompatibleProvider(
            apiKey: config.apiKey,
            baseURL: config.effectiveBaseURL,
            model: config.model.rawValue,
            timeout: config.timeout,
            requestsPerMinuteLimit: config.requestsPerMinuteLimit,
            fallbackProvider: fallbackProvider
        )

        let multiProvider = MultiProvider(defaultProvider: provider)
        try? await multiProvider.register(prefix: config.provider.rawValue, provider: provider)
        if let fallbackProvider, let fallback = config.fallbackProvider {
            try? await multiProvider.register(prefix: fallback.rawValue, provider: fallbackProvider)
        }
        await multiProvider.setModel("\(config.provider.rawValue)/\(config.model.rawValue)")
        return multiProvider
    }

    private static func compactSessionIfNeeded(session: (any Session)?) async throws {
        guard let fileSession = session as? FileBasedSession else { return }
        let itemCount = try await fileSession.getItemCount()
        guard itemCount >= Self.sessionCompactionThreshold else { return }
        try await fileSession.compact(retainLast: Self.sessionCompactionRetainCount)
    }

    private static func userFacingFailureResult(
        from error: Error,
        route: ExecutionRoute,
        loopBudget: LoopBudgetPolicy
    ) -> (result: AgentResult, stopReason: String)? {
        guard let agentError = error as? AgentError else { return nil }
        switch agentError {
        case .maxIterationsExceeded:
            let output = """
            I reached the execution limit for this request (\(loopBudget.maxIterations) iterations on the \(route.rawValue) route).
            Please retry with a narrower scope or ask me to execute one step at a time.
            """
            return (
                result: AgentResult(
                    output: output,
                    metadata: ["nanoclaw.loop_capped": .bool(true)]
                ),
                stopReason: "max_iterations"
            )
        case .timeout:
            return (
                result: AgentResult(
                    output: "I timed out before finishing this request. Please retry with a narrower scope or break it into smaller steps.",
                    metadata: ["nanoclaw.loop_timed_out": .bool(true)]
                ),
                stopReason: "timeout"
            )
        default:
            return nil
        }
    }

    private static func withMetrics(
        result: AgentResult,
        metrics: PerformanceMetrics,
        groupFolder: String,
        providerRoute: String,
        pseudoToolRejected: Bool,
        executionRoute: ExecutionRoute,
        attemptCount: Int,
        retryPolicy: ExecutionRetryPolicy,
        loopBudget: LoopBudgetPolicy,
        stopReason: String = "completed",
        extraMetadata: [String: SendableValue] = [:]
    ) -> AgentResult {
        var metadata = result.metadata
        for (key, value) in extraMetadata {
            metadata[key] = value
        }
        metadata["nanoclaw.group_folder"] = .string(groupFolder)
        metadata["nanoclaw.provider_route"] = .string(providerRoute)
        metadata["nanoclaw.tool_call_count"] = .int(result.toolCalls.count)
        metadata["nanoclaw.pseudo_tool_rejected"] = .bool(pseudoToolRejected)
        metadata["nanoclaw.execution_route"] = .string(executionRoute.rawValue)
        metadata["nanoclaw.retry_attempts"] = .int(attemptCount)
        metadata["nanoclaw.retry_max_attempts"] = .int(retryPolicy.maxAttempts)
        metadata["nanoclaw.loop_budget.max_iterations"] = .int(loopBudget.maxIterations)
        metadata["nanoclaw.loop_budget.max_tool_calls"] = .int(loopBudget.maxToolCalls)
        metadata["nanoclaw.loop_budget.timeout_seconds"] = .int(Self.timeoutSeconds(from: loopBudget.timeout))
        metadata["nanoclaw.loop_budget.session_compaction_threshold"] = .int(Self.sessionCompactionThreshold)
        metadata["nanoclaw.loop_budget.session_compaction_retain"] = .int(Self.sessionCompactionRetainCount)
        metadata["nanoclaw.stop_reason"] = .string(stopReason)
        metadata["metrics.totalDurationMs"] = .double(Double(metrics.totalDuration.components.seconds * 1000))
        metadata["metrics.toolCount"] = .int(metrics.toolCount)
        metadata["metrics.usedParallelExecution"] = .bool(metrics.usedParallelExecution)

        return AgentResult(
            output: Self.sanitizeUserFacingOutput(result.output),
            toolCalls: result.toolCalls,
            toolResults: result.toolResults,
            iterationCount: result.iterationCount,
            duration: result.duration,
            tokenUsage: result.tokenUsage,
            metadata: metadata
        )
    }

    private static func skillMetadata(from payload: SkillsContextPayload) -> [String: SendableValue] {
        [
            "nanoclaw.skills.injected_count": .int(payload.injectedSkillIDs.count),
            "nanoclaw.skills.injected_ids": .array(payload.injectedSkillIDs.map { .string($0) }),
            "nanoclaw.skills.injected_names": .array(payload.injectedSkillNames.map { .string($0) }),
            "nanoclaw.skills.truncated": .bool(payload.truncated),
            "nanoclaw.skills.resolver_applied": .bool(payload.resolverApplied),
            "nanoclaw.skills.resolver_selected": .bool(payload.selectedByResolver)
        ]
    }

    private static func sanitizeUserFacingOutput(_ output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return true }
            if trimmed.range(of: #"^\[Tool Result - .+\]:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
            if trimmed.range(of: #"^Based on my search\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
            if trimmed.range(of: #"^\*\*Summary of what I found:\*\*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return false
            }
            return true
        }

        let compacted = filtered.reduce(into: [String]()) { acc, line in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               acc.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                return
            }
            acc.append(line)
        }

        let normalized = compacted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : normalized
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
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return """
        You are \(name), a helpful AI assistant running in a NanoClaw container.

        You have access to various tools for:
        - Reading and writing files
        - Executing bash commands
        - Searching with grep and glob patterns
        - Fetching/searching the web through host broker tools
        - Managing group-scoped web allowlist policy
        - Sending Telegram messages (use send_message tool)
        - Scheduling recurring or one-time tasks

        Guidelines:
        1. Always use tools when available rather than guessing
        2. Read files before editing them
        3. Use atomic writes (write to temp file, then move)
        4. Respect the container filesystem boundaries (/workspace/group)
        5. For scheduled tasks, use schedule_task with appropriate schedule_type
        6. Be concise in your responses
        7. Never output raw tool-call code blocks like ```tool ...``` in your final answer
        8. Never include internal tool transcript text in final replies (for example, "[Tool Result - ...]", raw tool call logs, or "Based on my search, I'll ...").
        9. If you used send_message to deliver the final content, do not repeat the entire report again; give a short confirmation plus optional next action.
        10. For time-sensitive factual reports (news, launches, release status): include "As of \(today)" and a "Sources" section with publication dates. If fresh sources are unavailable or conflicting, say so clearly instead of guessing.

        When the user asks you to modify files:
        1. Read the file first
        2. Show what changes you plan to make
        3. Apply the changes
        4. Confirm what was done
        """
    }

    nonisolated private static func composeInstructions(
        baseInstructions: String,
        groupContext: String,
        persistentMemoryContext: String,
        isScheduledTask: Bool
    ) -> String {
        var sections: [String] = []
        if isScheduledTask {
            sections.append("[SCHEDULED TASK - You are running automatically, not in response to a user message. Use send_message if needed to communicate with the user.]")
        }

        let trimmedGroupContext = groupContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGroupContext.isEmpty {
            sections.append("## Group Context\n\n\(trimmedGroupContext)")
        }

        let trimmedMemoryContext = persistentMemoryContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMemoryContext.isEmpty {
            sections.append("## Persistent Memory\n\n\(trimmedMemoryContext)")
        }

        sections.append(baseInstructions)
        return sections.joined(separator: "\n\n---\n\n")
    }

    private static func loadPersistentMemoryContext(tokenBudget: Int) async -> String {
        let store = FileMemoryStore.default()
        do {
            return try await store.contextSnippet(tokenBudget: tokenBudget)
        } catch {
            return ""
        }
    }

    nonisolated static func explicitToolInvocation(
        for input: String,
        availableToolNames: Set<String>
    ) -> ExplicitToolInvocation? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()

        if availableToolNames.contains("focusrelay_cli"),
           let dueTodayArgs = explicitFocusRelayDueTodayArgs(for: lowered) {
            return ExplicitToolInvocation(
                toolName: "focusrelay_cli",
                arguments: [
                    "subcommand": .string("list-tasks"),
                    "args": .array(dueTodayArgs.map { .string($0) })
                ]
            )
        }

        if availableToolNames.contains("sub_agent"),
           containsMatch(
               in: lowered,
               pattern: #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?sub_agent(?:\s+tool)?\b"#
           ) {
            guard let prompt = extractedSubAgentPrompt(from: text), !prompt.isEmpty else {
                // Let the normal loop handle ambiguous/missing-argument sub-agent asks.
                return nil
            }
            var arguments: [String: SendableValue] = ["prompt": .string(prompt)]
            if let context = extractedSubAgentContext(from: text), !context.isEmpty {
                arguments["context"] = .string(context)
            }
            if let temperature = extractedSubAgentTemperature(from: text), !temperature.isEmpty {
                arguments["temperature"] = .string(temperature)
            }
            return ExplicitToolInvocation(toolName: "sub_agent", arguments: arguments)
        }

        if availableToolNames.contains("write_memory"),
           containsMatch(
               in: lowered,
               pattern: #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?write_memory(?:\s+tool)?\b"#
           ) {
            var arguments: [String: SendableValue] = [:]
            if let scope = firstCapture(in: text, pattern: #"\bscope\s+(chat|global)\b"#) {
                arguments["scope"] = .string(scope.lowercased())
            }
            if let mode = firstCapture(in: text, pattern: #"\bmode\s+(append|replace)\b"#) {
                arguments["mode"] = .string(mode.lowercased())
            }
            if let content = extractedWriteMemoryContent(from: text), !content.isEmpty {
                arguments["content"] = .string(content)
            }
            return ExplicitToolInvocation(toolName: "write_memory", arguments: arguments)
        }

        if availableToolNames.contains("send_message"),
           containsMatch(
               in: lowered,
               pattern: #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?send_message(?:\s+tool)?\b"#
           ) {
            var arguments: [String: SendableValue] = [:]
            if let message = extractedSendMessageField(from: text, field: "message"), !message.isEmpty {
                arguments["message"] = .string(message)
            } else if let alias = extractedSendMessageField(from: text, field: "text"), !alias.isEmpty {
                arguments["text"] = .string(alias)
            }
            if let attachmentPath = extractedSendMessageField(from: text, field: "attachment_path"), !attachmentPath.isEmpty {
                arguments["attachment_path"] = .string(attachmentPath)
            }
            if let caption = extractedSendMessageField(from: text, field: "caption"), !caption.isEmpty {
                arguments["caption"] = .string(caption)
            }
            // If no actionable fields were provided, let the normal loop handle it.
            guard !arguments.isEmpty else { return nil }
            return ExplicitToolInvocation(toolName: "send_message", arguments: arguments)
        }

        if availableToolNames.contains("mcp_host_cli"),
           let (serverID, args) = extractedMCPHostCLIInvocation(from: text) {
            var arguments: [String: SendableValue] = [
                "server_id": .string(serverID)
            ]
            if !args.isEmpty {
                arguments["args"] = .array(args.map { .string($0) })
            }
            return ExplicitToolInvocation(toolName: "mcp_host_cli", arguments: arguments)
        }

        if availableToolNames.contains("mcp_reload"),
           containsMatch(
               in: lowered,
               pattern: #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?mcp_reload(?:\s+tool)?\b"#
           ) {
            var arguments: [String: SendableValue] = [:]
            if let configPath = extractedMCPReloadConfigPath(from: text), !configPath.isEmpty {
                arguments["config_path"] = .string(configPath)
            }
            return ExplicitToolInvocation(toolName: "mcp_reload", arguments: arguments)
        }

        if availableToolNames.contains("focusrelay_cli"),
           let (subcommand, args) = extractedFocusRelayCLIInvocation(from: text) {
            var arguments: [String: SendableValue] = [
                "subcommand": .string(subcommand)
            ]
            if !args.isEmpty {
                arguments["args"] = .array(args.map { .string($0) })
            }
            return ExplicitToolInvocation(toolName: "focusrelay_cli", arguments: arguments)
        }

        if availableToolNames.contains("read_memory"),
           containsMatch(
               in: lowered,
               pattern: #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?read_memory(?:\s+tool)?\b"#
           ) {
            var arguments: [String: SendableValue] = [:]
            if let scope = firstCapture(in: text, pattern: #"\bscope\s+(chat|global)\b"#) {
                arguments["scope"] = .string(scope.lowercased())
            }
            return ExplicitToolInvocation(toolName: "read_memory", arguments: arguments)
        }

        if let skill = firstCapture(
            in: text,
            pattern: #"^\s*(?:please\s+)?deactivate\s+skill\s+[`\"]?([a-z0-9._-]+)[`\"]?\s*[.!?]?\s*$"#
        ), availableToolNames.contains("deactivate_skill") {
            return ExplicitToolInvocation(
                toolName: "deactivate_skill",
                arguments: ["skill": .string(skill)]
            )
        }

        if let skill = firstCapture(
            in: text,
            pattern: #"^\s*(?:please\s+)?activate\s+skill\s+[`\"]?([a-z0-9._-]+)[`\"]?\s*[.!?]?\s*$"#
        ), availableToolNames.contains("activate_skill") {
            return ExplicitToolInvocation(
                toolName: "activate_skill",
                arguments: ["skill": .string(skill)]
            )
        }

        let directTaskIDPatterns: [(String, String)] = [
            ("cancel_task", #"^\s*(?:please\s+)?cancel\s+(task-[a-z0-9._-]+)\s*[.!?]?\s*$"#),
            ("pause_task", #"^\s*(?:please\s+)?pause\s+(task-[a-z0-9._-]+)\s*[.!?]?\s*$"#),
            ("resume_task", #"^\s*(?:please\s+)?resume\s+(task-[a-z0-9._-]+)\s*[.!?]?\s*$"#)
        ]
        for (toolName, pattern) in directTaskIDPatterns {
            if let taskID = firstCapture(in: text, pattern: pattern),
               availableToolNames.contains(toolName) {
                return ExplicitToolInvocation(
                    toolName: toolName,
                    arguments: ["task_id": .string(taskID)]
                )
            }
        }

        let taskIDPatterns: [(String, String)] = [
            ("cancel_task", #"^\s*(?:please\s+)?cancel\s+task(?:\s*:\s*|\s+)[`\"]?(.+?)[`\"]?\s*[.!?]?\s*$"#),
            ("pause_task", #"^\s*(?:please\s+)?pause\s+task(?:\s*:\s*|\s+)[`\"]?(.+?)[`\"]?\s*[.!?]?\s*$"#),
            ("resume_task", #"^\s*(?:please\s+)?resume\s+task(?:\s*:\s*|\s+)[`\"]?(.+?)[`\"]?\s*[.!?]?\s*$"#)
        ]
        for (toolName, pattern) in taskIDPatterns {
            if let taskID = firstCapture(in: text, pattern: pattern),
               availableToolNames.contains(toolName) {
                return ExplicitToolInvocation(
                    toolName: toolName,
                    arguments: ["task_id": .string(taskID)]
                )
            }
        }

        let naturalVerbPatterns: [(String, [String])] = [
            ("list_tasks", [
                #"^\s*(?:please\s+)?(?:list|show)\s+(?:my\s+)?tasks\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?what\s+tasks\s+(?:do\s+you\s+have|are\s+scheduled)\s*[.!?]?\s*$"#
            ]),
            ("todo_read", [
                #"^\s*(?:please\s+)?(?:show|list|read)\s+(?:my\s+)?todo(?:\s+list)?\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?(?:show|list|read)\s+todos\s*[.!?]?\s*$"#
            ]),
            ("get_task_history", [
                #"^\s*(?:please\s+)?(?:show|get|list|read)\s+(?:task\s+)?history\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?show\s+recent\s+chat\s*[.!?]?\s*$"#
            ]),
            ("export_chat", [
                #"^\s*(?:please\s+)?export\s+(?:chat(?:\s+history)?|conversation(?:\s+history)?|history)\s*[.!?]?\s*$"#
            ]),
            ("list_skills", [
                #"^\s*(?:please\s+)?(?:list|show)\s+(?:my\s+)?skills\s*[.!?]?\s*$"#
            ]),
            ("sync_skills", [
                #"^\s*(?:please\s+)?(?:sync|refresh|reload)\s+skills\s*[.!?]?\s*$"#
            ]),
            ("focusrelay_inbox_tasks", [
                #"^\s*(?:please\s+)?(?:show|list)\s+(?:my\s+)?inbox\s+tasks\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?what(?:'s| is)\s+in\s+my\s+inbox\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?what\s+are\s+(?:the\s+)?tasks\s+in\s+my\s+inbox\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?how\s+many\s+tasks\s+are\s+in\s+my\s+inbox\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?(?:anything|what(?:'s| is))\s+in\s+my\s+omnifocus\s+inbox\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?what\s+are\s+(?:the\s+)?tasks\s+in\s+my\s+omnifocus\s+inbox\s*[.!?]?\s*$"#
            ]),
            ("focusrelay_bridge_health", [
                #"^\s*(?:please\s+)?(?:check|show)\s+focusrelay\s+(?:bridge\s+)?health\s*[.!?]?\s*$"#
            ]),
            ("mcp_status", [
                #"^\s*(?:please\s+)?(?:show|list|get)\s+(?:the\s+)?mcp\s+status\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?mcp\s+status\s*[.!?]?\s*$"#
            ]),
            ("mcp_reload", [
                #"^\s*(?:please\s+)?(?:reload|refresh)\s+mcp(?:\s+tools?)?\s*[.!?]?\s*$"#,
                #"^\s*(?:please\s+)?mcp\s+reload\s*[.!?]?\s*$"#
            ])
        ]
        for (toolName, patterns) in naturalVerbPatterns where availableToolNames.contains(toolName) {
            if patterns.contains(where: { containsMatch(in: lowered, pattern: $0) }) {
                return ExplicitToolInvocation(
                    toolName: toolName,
                    arguments: [:]
                )
            }
        }

        let patterns = [
            #"^\s*`([a-z0-9_-]{2,})`\s+tool\s*[.!?]?\s*$"#,
            #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?([a-z0-9_-]{2,})\s+tool\s*[.!?]?\s*$"#
        ]

        for pattern in patterns {
            if let candidate = firstCapture(in: lowered, pattern: pattern),
               availableToolNames.contains(candidate) {
                return ExplicitToolInvocation(
                    toolName: candidate,
                    arguments: [:]
                )
            }
        }

        return nil
    }

    nonisolated private static func extractedFocusRelayCLIInvocation(
        from text: String
    ) -> (subcommand: String, args: [String])? {
        let patterns = [
            #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?focusrelay_cli(?:\s+tool)?\s+subcommand\s+([a-z0-9_-]+)(?:\s+args\s+(.+))?\s*[.!?]?\s*$"#,
            #"^\s*(?:please\s+)?(?:run|use|call)\s+focusrelay\s+([a-z0-9_-]+)(?:\s+(.+))?\s*[.!?]?\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let subcommandRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let subcommand = String(text[subcommandRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !subcommand.isEmpty else { continue }

            let rawArgs: String
            if match.numberOfRanges >= 3,
               let argsRange = Range(match.range(at: 2), in: text) {
                rawArgs = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawArgs = ""
            }
            return (subcommand, tokenizeCLIArguments(rawArgs))
        }
        return nil
    }

    nonisolated private static func explicitFocusRelayDueTodayArgs(for loweredInput: String) -> [String]? {
        guard loweredInput.contains("omnifocus"),
              loweredInput.contains("due today") else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let dueAfter = formatter.string(from: startOfDay)
        let dueBefore = formatter.string(from: startOfTomorrow)

        return [
            "--fields", "id,name,dueDate",
            "--completed", "false",
            "--due-after", dueAfter,
            "--due-before", dueBefore,
            "--limit", "50"
        ]
    }

    nonisolated private static func extractedMCPHostCLIInvocation(
        from text: String
    ) -> (serverID: String, args: [String])? {
        let patterns = [
            #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?mcp_host_cli(?:\s+tool)?\s+server(?:_id)?\s+([a-z0-9._-]+)(?:\s+args\s+(.+))?\s*[.!?]?\s*$"#,
            #"^\s*(?:please\s+)?(?:run|use|call)\s+mcp\s+host\s+cli\s+([a-z0-9._-]+)(?:\s+(.+))?\s*[.!?]?\s*$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let serverRange = Range(match.range(at: 1), in: text) else {
                continue
            }

            let serverID = String(text[serverRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverID.isEmpty else { continue }

            let rawArgs: String
            if match.numberOfRanges >= 3,
               let argsRange = Range(match.range(at: 2), in: text) {
                rawArgs = String(text[argsRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawArgs = ""
            }
            return (serverID, tokenizeCLIArguments(rawArgs))
        }
        return nil
    }

    nonisolated private static func extractedMCPReloadConfigPath(from text: String) -> String? {
        if let quoted = firstCapture(in: text, pattern: #"\bconfig(?:_path)?\s+\"([^\"]+)\""#), !quoted.isEmpty {
            return quoted
        }
        if let quoted = firstCapture(in: text, pattern: #"\bconfig(?:_path)?\s+'([^']+)'"#), !quoted.isEmpty {
            return quoted
        }
        if let raw = firstCapture(in: text, pattern: #"\bconfig(?:_path)?\s+(\S+)"#), !raw.isEmpty {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    nonisolated private static func tokenizeCLIArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { token in
                token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func extractedWriteMemoryContent(from text: String) -> String? {
        if let quoted = firstCapture(in: text, pattern: #"\bcontent\s+\"([^\"]+)\""#), !quoted.isEmpty {
            return quoted
        }
        if let quoted = firstCapture(in: text, pattern: #"\bcontent\s+'([^']+)'"#), !quoted.isEmpty {
            return quoted
        }
        if let trailing = firstCapture(in: text, pattern: #"\bcontent\s+(.+?)\s*[.!?]?\s*$"#) {
            let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    nonisolated private static func extractedSendMessageField(from text: String, field: String) -> String? {
        let escapedField = NSRegularExpression.escapedPattern(for: field)
        if let quoted = firstCapture(in: text, pattern: #"\b\#(escapedField)\s+\"([^\"]+)\""#), !quoted.isEmpty {
            return quoted
        }
        if let quoted = firstCapture(in: text, pattern: #"\b\#(escapedField)\s+'([^']+)'"#), !quoted.isEmpty {
            return quoted
        }
        if let trailing = firstCapture(in: text, pattern: #"\b\#(escapedField)\s+(.+?)\s*(?:\band\b|\s*[.!?]?\s*$)"#) {
            let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    nonisolated private static func extractedSubAgentPrompt(from text: String) -> String? {
        if let quoted = firstCapture(in: text, pattern: #"\bprompt\s+\"([^\"]+)\""#), !quoted.isEmpty {
            return quoted
        }
        if let quoted = firstCapture(in: text, pattern: #"\bprompt\s+'([^']+)'"#), !quoted.isEmpty {
            return quoted
        }
        return nil
    }

    nonisolated private static func extractedSubAgentContext(from text: String) -> String? {
        if let quoted = firstCapture(in: text, pattern: #"\bcontext\s+\"([^\"]+)\""#), !quoted.isEmpty {
            return quoted
        }
        if let quoted = firstCapture(in: text, pattern: #"\bcontext\s+'([^']+)'"#), !quoted.isEmpty {
            return quoted
        }
        return nil
    }

    nonisolated private static func extractedSubAgentTemperature(from text: String) -> String? {
        if let raw = firstCapture(in: text, pattern: #"\btemperature\s+(-?\d+(?:\.\d+)?)\b"#), !raw.isEmpty {
            return raw
        }
        return nil
    }

    nonisolated private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func containsMatch(in text: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    nonisolated private static func isPaginationContinuationPrompt(_ input: String) -> Bool {
        let patterns = [
            #"^\s*(?:please\s+)?show\s+more(?:\s+(?:results|items|tasks))?(?:\s+\d{1,3})?\s*[.!?]?\s*$"#,
            #"^\s*(?:please\s+)?(?:next|next\s+page)(?:\s+\d{1,3})?\s*[.!?]?\s*$"#,
            #"^\s*(?:please\s+)?continue(?:\s+(?:results|items|tasks))?(?:\s+\d{1,3})?\s*[.!?]?\s*$"#
        ]
        let lowered = input.lowercased()
        return patterns.contains { containsMatch(in: lowered, pattern: $0) }
    }

    nonisolated private static func paginationContinuationLimitOverride(_ input: String) -> Int? {
        let lowered = input.lowercased()
        guard let rawValue = firstCapture(
            in: lowered,
            pattern: #"^\s*(?:please\s+)?(?:show\s+more|next(?:\s+page)?|continue)(?:\s+(?:results|items|tasks))?\s+(\d{1,3})\s*[.!?]?\s*$"#
        ),
        let parsed = Int(rawValue) else {
            return nil
        }
        return max(1, min(parsed, 100))
    }

    nonisolated private static func removingCursorArguments(from args: [String]) -> [String] {
        var cleaned: [String] = []
        var skipNext = false
        for token in args {
            if skipNext {
                skipNext = false
                continue
            }
            if token == "--cursor" {
                skipNext = true
                continue
            }
            if token.hasPrefix("--cursor=") {
                continue
            }
            cleaned.append(token)
        }
        return cleaned
    }

    nonisolated private static func containsCursorArgument(in args: [String]) -> Bool {
        args.contains(where: { $0 == "--cursor" || $0.hasPrefix("--cursor=") })
    }

    nonisolated private static func flagValue(named flag: String, in args: [String]) -> String? {
        for (index, token) in args.enumerated() {
            if token == flag {
                let nextIndex = index + 1
                guard nextIndex < args.count else { return nil }
                return args[nextIndex]
            }
            if token.hasPrefix("\(flag)=") {
                let value = String(token.dropFirst(flag.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    nonisolated private static func replacingOrAppendingFlag(
        named flag: String,
        value: String,
        in args: [String]
    ) -> [String] {
        var updated: [String] = []
        var skipNext = false
        var replaced = false
        for token in args {
            if skipNext {
                skipNext = false
                continue
            }
            if token == flag {
                if !replaced {
                    updated.append(flag)
                    updated.append(value)
                    replaced = true
                }
                skipNext = true
                continue
            }
            if token.hasPrefix("\(flag)=") {
                if !replaced {
                    updated.append(flag)
                    updated.append(value)
                    replaced = true
                }
                continue
            }
            updated.append(token)
        }
        if !replaced {
            updated.append(flag)
            updated.append(value)
        }
        return updated
    }

    nonisolated private static func renderExplicitToolOutput(toolName: String, rawOutput: String) -> String {
        guard toolName.hasPrefix("mcp_"),
              let value = parseMCPJSONValue(from: rawOutput) else {
            return rawOutput
        }

        if let rendered = renderMCPJSONValue(value) {
            return rendered
        }
        return rawOutput
    }

    nonisolated private static func renderUserFacingMCPOutputIfNeeded(_ result: AgentResult) -> AgentResult {
        guard let lastMCPToolName = result.toolCalls.last(where: { $0.toolName.hasPrefix("mcp_") })?.toolName else {
            return result
        }

        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmedOutput.first, first == "{" || first == "[" || first == "\"" else {
            return result
        }

        let rendered = renderExplicitToolOutput(toolName: lastMCPToolName, rawOutput: trimmedOutput)
        let hinted = appendPaginationHintIfNeeded(
            toolName: lastMCPToolName,
            rawOutput: trimmedOutput,
            renderedOutput: rendered
        )
        guard hinted != trimmedOutput else {
            return result
        }

        var metadata = result.metadata
        metadata["nanoclaw.mcp_output_formatted"] = .bool(true)
        return AgentResult(
            output: hinted,
            toolCalls: result.toolCalls,
            toolResults: result.toolResults,
            iterationCount: result.iterationCount,
            duration: result.duration,
            metadata: metadata
        )
    }

    nonisolated private static func appendPaginationHintIfNeeded(
        toolName: String,
        rawOutput: String,
        renderedOutput: String
    ) -> String {
        guard toolName == "mcp_host_cli",
              let nextCursor = extractNextCursor(fromRawOutput: rawOutput) else {
            return renderedOutput
        }
        return renderedOutput
            + "\nSay \"show more\" to load the next page (cursor \(nextCursor))."
            + "\nYou can also say \"show more <n>\" to change page size."
    }

    nonisolated private static func overrideTerminalPaginationOutputIfNeeded(
        toolName: String,
        arguments: [String: SendableValue],
        rawOutput: String,
        renderedOutput: String
    ) -> String {
        guard toolName == "mcp_host_cli" else {
            return renderedOutput
        }
        let args = arguments["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard containsCursorArgument(in: args),
              let itemCount = extractItemsCount(fromRawOutput: rawOutput),
              itemCount == 0 else {
            return renderedOutput
        }
        return "No additional items were returned for the next page. You’ve reached the end (or the cursor is stale)."
    }

    nonisolated private static func parseMCPJSONValue(from rawOutput: String) -> Any? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }

        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let jsonString = value as? String,
               let nestedData = jsonString.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: nestedData, options: [.fragmentsAllowed]) {
                return nested
            }
            return value
        }
        return nil
    }

    nonisolated private static func extractNextCursor(fromRawOutput rawOutput: String) -> String? {
        guard let value = parseMCPJSONValue(from: rawOutput) else {
            return nil
        }
        return extractNextCursor(fromMCPJSONValue: value)
    }

    nonisolated private static func extractNextCursor(fromMCPJSONValue value: Any) -> String? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        if let cursor = object["nextCursor"] as? String {
            let trimmed = cursor.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = object["nextCursor"] as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    nonisolated private static func extractItemsCount(fromRawOutput rawOutput: String) -> Int? {
        guard let value = parseMCPJSONValue(from: rawOutput),
              let object = value as? [String: Any],
              let items = object["items"] as? [Any] else {
            return nil
        }
        return items.count
    }

    nonisolated private static func recoveredPaginationRawOutput(
        fromSupersetRawOutput rawOutput: String,
        offset: Int,
        pageSize: Int,
        expandedLimit: Int
    ) -> String? {
        guard pageSize > 0,
              offset >= 0,
              let value = parseMCPJSONValue(from: rawOutput),
              let object = value as? [String: Any],
              let allItems = object["items"] as? [Any] else {
            return nil
        }

        guard offset < allItems.count else { return nil }
        let end = min(allItems.count, offset + pageSize)
        let pageItems = Array(allItems[offset..<end])
        guard !pageItems.isEmpty else { return nil }

        var recovered: [String: Any] = ["items": pageItems, "returnedCount": pageItems.count]
        if let totalCount = object["totalCount"] {
            recovered["totalCount"] = totalCount
        }

        if let existingNextCursor = extractNextCursor(fromMCPJSONValue: object),
           let existingNext = Int(existingNextCursor),
           existingNext > offset {
            recovered["nextCursor"] = existingNextCursor
        } else if end < allItems.count {
            recovered["nextCursor"] = String(end)
        } else if allItems.count == expandedLimit {
            // Upstream may have truncated before offset pagination was applied.
            recovered["nextCursor"] = String(end)
        }

        guard JSONSerialization.isValidJSONObject(recovered),
              let data = try? JSONSerialization.data(withJSONObject: recovered, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    nonisolated private static func renderMCPJSONValue(_ value: Any) -> String? {
        if let object = value as? [String: Any] {
            return renderMCPJSONObject(object)
        }
        if let array = value as? [[String: Any]] {
            return renderMCPJSONArray(array)
        }
        return nil
    }

    nonisolated private static func renderMCPJSONObject(_ object: [String: Any]) -> String? {

        if let plugin = object["plugin"] as? String,
           let version = object["version"] as? String,
           let ok = object["ok"] as? Bool {
            let status = ok ? "healthy" : "unhealthy"
            return "\(plugin) is \(status) (version \(version))."
        }

        if let items = object["items"] as? [[String: Any]] {
            if items.isEmpty {
                return "No items found."
            }

            let maxItems = 15
            let shown = min(items.count, maxItems)
            var lines: [String] = ["Found \(items.count) item(s):"]
            for (index, item) in items.prefix(maxItems).enumerated() {
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = (item["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let renderedName = (name?.isEmpty == false) ? name! : "(untitled)"
                if let id, !id.isEmpty {
                    lines.append("\(index + 1). \(renderedName) (id: \(id))")
                } else {
                    lines.append("\(index + 1). \(renderedName)")
                }
            }

            if items.count > shown {
                lines.append("...and \(items.count - shown) more.")
            }
            if let cursor = object["nextCursor"] as? String,
               !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Next cursor: \(cursor)")
            }
            return lines.joined(separator: "\n")
        }

        if let projects = object["projects"] as? Int, let actions = object["actions"] as? Int {
            return "Project counts:\n- Projects: \(projects)\n- Actions: \(actions)"
        }

        let scalarLines = object.keys.sorted().compactMap { key -> String? in
            guard let scalar = renderMCPScalar(object[key]) else { return nil }
            return "\(key): \(scalar)"
        }
        if !scalarLines.isEmpty {
            return scalarLines.joined(separator: "\n")
        }

        return nil
    }

    nonisolated private static func renderMCPJSONArray(_ rows: [[String: Any]]) -> String? {
        guard !rows.isEmpty else {
            return "No items found."
        }

        let maxRows = 15
        var lines: [String] = ["Found \(rows.count) item(s):"]
        for (index, item) in rows.prefix(maxRows).enumerated() {
            if let name = item["name"] as? String,
               let id = item["id"] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("\(index + 1). \(name) (id: \(id))")
                continue
            }

            let summary = item.keys.sorted().compactMap { key -> String? in
                guard let scalar = renderMCPScalar(item[key]) else { return nil }
                return "\(key)=\(scalar)"
            }.joined(separator: ", ")

            if summary.isEmpty {
                lines.append("\(index + 1). (item)")
            } else {
                lines.append("\(index + 1). \(summary)")
            }
        }

        if rows.count > maxRows {
            lines.append("...and \(rows.count - maxRows) more.")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func renderMCPScalar(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let int as Int:
            return "\(int)"
        case let double as Double:
            return "\(double)"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    nonisolated private static func renderMCPJSONObject(_ value: Any) -> String? {
        if let object = value as? [String: Any] {
            return renderMCPJSONObject(object)
        }
        if let rows = value as? [[String: Any]] {
            return renderMCPJSONArray(rows)
        }
        return nil
    }

    private static func createDefaultTools(
        groupFolder: String,
        chatJid: String,
        isMain: Bool,
        mcpStatus: MCPRuntimeStatus = .unconfigured
    ) -> [any Tool] {
        let memoryStore = FileMemoryStore.default()
        let fileTools: [any Tool] = [
            ReadTool(),
            WriteTool(),
            EditTool(),
            GlobTool(),
            GrepTool(),
            MCPStatusTool(status: mcpStatus),
            MCPHostCLITool(),
            MCPReloadTool(),
            ReadMemoryTool(store: memoryStore),
            WriteMemoryTool(store: memoryStore),
            TodoReadTool(),
            TodoWriteTool(),
            ListSkillsTool(),
            ActivateSkillTool(),
            DeactivateSkillTool(),
            SyncSkillsTool(),
            GetTaskHistoryTool(),
            ExportChatTool(),
            SubAgentTool(),
            WebFetchTool(),
            WebSearchTool(),
            WebPolicyAddDomainTool(),
            WebPolicyRemoveDomainTool(),
            WebPolicyListTool(),
            FocusRelayInboxTasksTool(),
            FocusRelayCLITool(),
            FocusRelayBridgeHealthTool(),
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

        return Self.wrapSideEffectTools(fileTools + ipcTools)
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

private struct SnapshotTask {
    let id: String
    let groupFolder: String
    let status: String
    let prompt: String
}

private enum SnapshotTaskResolution {
    case matched(SnapshotTask)
    case notFound
    case ambiguous([SnapshotTask])
}

private enum MatchedSnapshotTaskResult {
    case matched(SnapshotTask)
    case failure(String)
}

private enum TaskActionVerb: String {
    case cancel = "cancel"
    case pause = "pause"
    case resume = "resume"
}

private func loadSnapshotTasks() -> [SnapshotTask] {
    let snapshotPath = "\(resolveIPCBasePath())/current_tasks.json"
    guard FileManager.default.fileExists(atPath: snapshotPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath)),
          let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
        return []
    }

    return items.compactMap { item in
        guard let id = item["id"] as? String else { return nil }
        let groupFolder = (item["groupFolder"] as? String) ?? ""
        let status = (item["status"] as? String) ?? ""
        let prompt = (item["prompt"] as? String) ?? ""
        return SnapshotTask(id: id, groupFolder: groupFolder, status: status, prompt: prompt)
    }
}

private func hasTaskSnapshot() -> Bool {
    let snapshotPath = "\(resolveIPCBasePath())/current_tasks.json"
    return FileManager.default.fileExists(atPath: snapshotPath)
}

private func resolveSnapshotTask(reference: String, groupFolder: String) -> SnapshotTaskResolution {
    let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return .notFound }
    let lookup = normalized.lowercased()
    let tasks = loadSnapshotTasks().filter { $0.groupFolder == groupFolder }
    guard !tasks.isEmpty else { return .notFound }

    if let byID = tasks.first(where: { $0.id.lowercased() == lookup }) {
        return .matched(byID)
    }

    let promptExactMatches = tasks.filter {
        $0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lookup
    }
    if promptExactMatches.count == 1, let task = promptExactMatches.first {
        return .matched(task)
    }
    if promptExactMatches.count > 1 {
        return .ambiguous(promptExactMatches)
    }

    let promptFuzzyMatches = tasks.filter { $0.prompt.lowercased().contains(lookup) }
    if promptFuzzyMatches.count == 1, let task = promptFuzzyMatches.first {
        return .matched(task)
    }
    if promptFuzzyMatches.count > 1 {
        return .ambiguous(promptFuzzyMatches)
    }

    return .notFound
}

private func taskPromptSnippet(_ prompt: String, maxLength: Int = 72) -> String {
    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "(no description)" }
    if normalized.count <= maxLength { return normalized }
    let prefix = normalized.prefix(max(0, maxLength - 3))
    return "\(prefix)..."
}

private func taskLineSummary(_ task: SnapshotTask) -> String {
    "\(task.id) - \(taskPromptSnippet(task.prompt)) [\(task.status)]"
}

private func taskActionSuccessMessage(
    actionTitle: String,
    taskID: String,
    task: SnapshotTask?
) -> String {
    guard let task else {
        return "✅ **\(actionTitle)** `\(taskID)`."
    }
    return """
✅ **\(actionTitle)** `\(taskID)`
• Summary: \(taskPromptSnippet(task.prompt))
• Previous status: \(task.status)
"""
}

private func taskAlreadyInStateMessage(
    desiredState: String,
    task: SnapshotTask
) -> String {
    """
ℹ️ Task `\(task.id)` is already **\(desiredState)**.
• Summary: \(taskPromptSnippet(task.prompt))
• Current status: \(task.status)
"""
}

private func ambiguousTaskReferenceMessage(
    action: TaskActionVerb,
    reference: String,
    matches: [SnapshotTask]
) -> String {
    let sortedMatches = matches.sorted { $0.id < $1.id }
    let lines = sortedMatches.map(taskLineSummary).joined(separator: "\n- ")
    return """
I found multiple tasks matching "\(reference)". Which one should I \(action.rawValue)?
- \(lines)
Reply with the exact task ID, for example: "Please \(action.rawValue) task \(sortedMatches[0].id)".
"""
}

private func matchedSnapshotTask(
    action: TaskActionVerb,
    taskReference: String,
    groupFolder: String
) -> MatchedSnapshotTaskResult {
    switch resolveSnapshotTask(reference: taskReference, groupFolder: groupFolder) {
    case .matched(let task):
        return .matched(task)
    case .notFound:
        return .failure("I couldn’t find a task matching \"\(taskReference)\". Try \"Please list my tasks\" to see exact IDs.")
    case .ambiguous(let matches):
        return .failure(ambiguousTaskReferenceMessage(action: action, reference: taskReference, matches: matches))
    }
}

// MARK: - IPC Tool Wrappers

/// Wrapper for SendMessageTool that provides proper initialization.
struct SendMessageToolWrapper: Tool {
    let name = "send_message"
    let description = "Sends a Telegram message to the group (text and optional attachment)"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "message", description: "The message content to send", type: .string, isRequired: false),
        ToolParameter(name: "text", description: "Alias for message content", type: .string, isRequired: false),
        ToolParameter(name: "attachment_path", description: "Optional container-local file path to send as Telegram document", type: .string, isRequired: false),
        ToolParameter(name: "caption", description: "Optional caption for attachment", type: .string, isRequired: false)
    ]
    
    let chatJid: String
    let groupFolder: String
    
    func execute(arguments: [String: SendableValue]) async throws -> SendableValue {
        let message = (arguments["message"]?.stringValue ?? arguments["text"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentPath = arguments["attachment_path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = arguments["caption"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty, attachmentPath?.isEmpty ?? true {
            throw AgentError.invalidToolArguments(
                toolName: name,
                reason: "send_message requires message/text or attachment_path"
            )
        }
        let idempotencyKey = resolvedIdempotencyKey(toolName: name, arguments: arguments)
        let ipcDir = "\(resolveIPCBasePath())/messages"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        
        var payload: [String: Any] = [
            "type": "send_message",
            "chat_jid": chatJid,
            "group_folder": groupFolder,
            "message": message,
            "idempotency_key": idempotencyKey,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let attachmentPath, !attachmentPath.isEmpty {
            payload["attachment_path"] = attachmentPath
        }
        if let caption, !caption.isEmpty {
            payload["caption"] = caption
        }
        
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
        let idempotencyKey = resolvedIdempotencyKey(toolName: name, arguments: arguments)
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
            "idempotency_key": idempotencyKey,
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
    let displayTimeZone: TimeZone

    init(groupFolder: String, isMain: Bool, displayTimeZone: TimeZone = .current) {
        self.groupFolder = groupFolder
        self.isMain = isMain
        self.displayTimeZone = displayTimeZone
    }

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

        let lines = filtered.enumerated().map { index, item -> String in
            let id = (item["id"] as? String) ?? "unknown"
            let prompt = (item["prompt"] as? String) ?? "(no prompt)"
            let scheduleType = (item["schedule_type"] as? String) ?? "unknown"
            let scheduleValue = (item["schedule_value"] as? String) ?? "unknown"
            let status = (item["status"] as? String) ?? "unknown"
            let nextRun = (item["next_run"] as? String) ?? "n/a"
            let schedulerTimeZone = (item["scheduler_time_zone"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let promptSummary = taskPromptSnippet(prompt, maxLength: 90)
            let scheduleSummary = humanReadableSchedule(
                scheduleType: scheduleType,
                scheduleValue: scheduleValue,
                schedulerTimeZoneIdentifier: schedulerTimeZone
            )
            let statusSummary = status == "active" ? "Active" : (status == "paused" ? "Paused" : status.capitalized)
            let nextRunSummary = formattedNextRun(nextRun, preferredTimeZoneIdentifier: schedulerTimeZone)
            return """
\(index + 1). Task ID: \(id)
   Status: \(statusSummary)
   Schedule: \(scheduleSummary)
   Next run: \(nextRunSummary)
   Summary: \(promptSummary)
"""
        }

        let header = "Scheduled tasks (\(filtered.count)):"
        let duplicateHint = duplicateTaskHint(from: filtered)
        let body = header + "\n\n" + lines.joined(separator: "\n")
        if duplicateHint.isEmpty {
            return .string(body)
        }
        return .string(body + "\n\n" + duplicateHint)
    }

    private func humanReadableSchedule(
        scheduleType: String,
        scheduleValue: String,
        schedulerTimeZoneIdentifier: String?
    ) -> String {
        let timeZoneSuffix: String = {
            guard let identifier = schedulerTimeZoneIdentifier, !identifier.isEmpty else {
                return ""
            }
            return " (\(identifier))"
        }()
        if scheduleType == "cron" {
            let parts = scheduleValue.split(separator: " ")
            if parts.count == 5,
               let minute = Int(parts[0]),
               let hour = Int(parts[1]),
               parts[2] == "*", parts[3] == "*", parts[4] == "*" {
                return "Daily at " + String(format: "%02d:%02d", hour, minute) + timeZoneSuffix
            }
            return "Cron (\(scheduleValue))" + timeZoneSuffix
        }
        if scheduleType == "once" {
            return "One-time (\(scheduleValue))"
        }
        if scheduleType == "interval" {
            return "Interval (\(scheduleValue))"
        }
        return "\(scheduleType.capitalized) (\(scheduleValue))"
    }

    private func formattedNextRun(_ raw: String, preferredTimeZoneIdentifier: String?) -> String {
        guard raw != "n/a" else { return raw }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: raw)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: raw)
        }
        guard let parsedDate = date else {
            return raw
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let identifier = preferredTimeZoneIdentifier,
           let resolved = TimeZone(identifier: identifier) {
            formatter.timeZone = resolved
        } else {
            formatter.timeZone = displayTimeZone
        }
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'GMT'XXX"
        let local = formatter.string(from: parsedDate)
            .replacingOccurrences(of: "GMTZ", with: "GMT+00:00")
        return "\(local) (UTC \(raw))"
    }

    private func duplicateTaskHint(from items: [[String: Any]]) -> String {
        func normalizedPrompt(_ value: String) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }

        var grouped: [String: [String]] = [:]
        var displayPromptByKey: [String: String] = [:]
        for item in items {
            guard let id = item["id"] as? String,
                  let prompt = item["prompt"] as? String else {
                continue
            }
            let key = normalizedPrompt(prompt)
            guard !key.isEmpty else { continue }
            grouped[key, default: []].append(id)
            if displayPromptByKey[key] == nil {
                displayPromptByKey[key] = taskPromptSnippet(prompt, maxLength: 60)
            }
        }

        let duplicates = grouped
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
        guard !duplicates.isEmpty else {
            return ""
        }

        let details = duplicates.map { key, ids in
            let sortedIDs = ids.sorted()
            let joinedIDs = sortedIDs.joined(separator: ", ")
            let prompt = displayPromptByKey[key] ?? "(no description)"
            return "- \(joinedIDs) -> \(prompt)"
        }

        return """
I found potential duplicate tasks:
\(details.joined(separator: "\n"))
If you'd like, say: "Please cancel task <task-id>" for the duplicate you want removed.
"""
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
        let idempotencyKey = resolvedIdempotencyKey(toolName: name, arguments: arguments)
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }
        let snapshotAvailable = hasTaskSnapshot()
        let canonicalTaskID: String
        let matchedTask: SnapshotTask?
        if snapshotAvailable {
            switch matchedSnapshotTask(action: .pause, taskReference: taskId, groupFolder: resolvedGroupFolder()) {
            case .matched(let task):
                if task.status == "paused" {
                    return .string(taskAlreadyInStateMessage(desiredState: "paused", task: task))
                }
                canonicalTaskID = task.id
                matchedTask = task
            case .failure(let message):
                return .string(message)
            }
        } else {
            canonicalTaskID = taskId
            matchedTask = nil
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "pause_task",
            "task_id": canonicalTaskID,
            "group_folder": resolvedGroupFolder(),
            "idempotency_key": idempotencyKey,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        if snapshotAvailable {
            return .string(taskActionSuccessMessage(actionTitle: "Paused task", taskID: canonicalTaskID, task: matchedTask))
        }
        return .string("Task \(canonicalTaskID) pause requested")
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
        let idempotencyKey = resolvedIdempotencyKey(toolName: name, arguments: arguments)
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }
        let snapshotAvailable = hasTaskSnapshot()
        let canonicalTaskID: String
        let matchedTask: SnapshotTask?
        if snapshotAvailable {
            switch matchedSnapshotTask(action: .resume, taskReference: taskId, groupFolder: resolvedGroupFolder()) {
            case .matched(let task):
                if task.status == "active" {
                    return .string(taskAlreadyInStateMessage(desiredState: "active", task: task))
                }
                canonicalTaskID = task.id
                matchedTask = task
            case .failure(let message):
                return .string(message)
            }
        } else {
            canonicalTaskID = taskId
            matchedTask = nil
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "resume_task",
            "task_id": canonicalTaskID,
            "group_folder": resolvedGroupFolder(),
            "idempotency_key": idempotencyKey,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        if snapshotAvailable {
            return .string(taskActionSuccessMessage(actionTitle: "Resumed task", taskID: canonicalTaskID, task: matchedTask))
        }
        return .string("Task \(canonicalTaskID) resume requested")
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
        let idempotencyKey = resolvedIdempotencyKey(toolName: name, arguments: arguments)
        guard !taskId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .string("Error: missing task_id")
        }
        let snapshotAvailable = hasTaskSnapshot()
        let canonicalTaskID: String
        let matchedTask: SnapshotTask?
        if snapshotAvailable {
            switch matchedSnapshotTask(action: .cancel, taskReference: taskId, groupFolder: resolvedGroupFolder()) {
            case .matched(let task):
                canonicalTaskID = task.id
                matchedTask = task
            case .failure(let message):
                return .string(message)
            }
        } else {
            canonicalTaskID = taskId
            matchedTask = nil
        }

        let ipcDir = "\(resolveIPCBasePath())/tasks"
        let filename = "\(UUID().uuidString).json"
        let filepath = "\(ipcDir)/\(filename)"
        let payload: [String: Any] = [
            "type": "cancel_task",
            "task_id": canonicalTaskID,
            "group_folder": resolvedGroupFolder(),
            "idempotency_key": idempotencyKey,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: URL(fileURLWithPath: filepath))

        if snapshotAvailable {
            return .string(taskActionSuccessMessage(actionTitle: "Canceled task", taskID: canonicalTaskID, task: matchedTask))
        }
        return .string("Task \(canonicalTaskID) cancel requested")
    }
}

// MARK: - NanoClawAgentResult

/// Result type specific to NanoClawAgent (for CLI compatibility).
public struct NanoClawAgentResult: Sendable {
    let status: String
    let result: String
    let toolCallsCount: Int
    let newSessionId: String
    
    var json: String {
        let dict: [String: Any] = [
            "status": status,
            "result": result,
            "tool_calls_count": toolCallsCount,
            "newSessionId": newSessionId
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8)!
    }
}
