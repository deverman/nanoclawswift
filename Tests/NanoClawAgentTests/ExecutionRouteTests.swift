import Testing

@testable import NanoClawAgent

@Test
func testExecutionRouteUsesToolCallingForSimplePrompt() {
    let route = NanoClawAgent.executionRoute(for: "What is 2 + 2?")
    #expect(route == .toolCalling)
}

@Test
func testExecutionRouteUsesPlanAndExecuteForMultiStepPrompt() {
    let route = NanoClawAgent.executionRoute(
        for: "First gather recent updates, then compare alternatives, and finally produce a rollout plan."
    )
    #expect(route == .planAndExecute)
}

@Test
func testExecutionRouteUsesPlanAndExecuteForMissedScheduledReportRecovery() {
    let route = NanoClawAgent.executionRoute(
        for: "I didn't get my morning report can you send it?"
    )
    #expect(route == .planAndExecute)
}

@Test
func testExecutionRouteUsesPlanAndExecuteForUnicodeApostropheMissedReportPrompt() {
    let route = NanoClawAgent.executionRoute(
        for: "I didn’t get my morning report can you send it?"
    )
    #expect(route == .planAndExecute)
}

@Test
func testExplicitToolInvocationParsesUseToolCommand() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please use the list_skills tool",
        availableToolNames: ["list_skills", "activate_skill"]
    )
    #expect(invocation?.toolName == "list_skills")
}

@Test
func testExplicitToolInvocationParsesActivateSkillCommand() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please activate skill focus-mode",
        availableToolNames: ["list_skills", "activate_skill", "deactivate_skill"]
    )
    #expect(invocation?.toolName == "activate_skill")
    #expect(invocation?.arguments["skill"]?.stringValue == "focus-mode")
}

@Test
func testExplicitToolInvocationParsesDeactivateSkillCommand() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please deactivate skill focus-mode",
        availableToolNames: ["list_skills", "activate_skill", "deactivate_skill"]
    )
    #expect(invocation?.toolName == "deactivate_skill")
    #expect(invocation?.arguments["skill"]?.stringValue == "focus-mode")
}

@Test
func testExplicitToolInvocationParsesListTasksVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please list my tasks",
        availableToolNames: ["list_tasks"]
    )
    #expect(invocation?.toolName == "list_tasks")
}

@Test
func testExplicitToolInvocationParsesOmniFocusInboxNaturalVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Anything in my OmniFocus inbox?",
        availableToolNames: ["focusrelay_inbox_tasks"]
    )
    #expect(invocation?.toolName == "focusrelay_inbox_tasks")
}

@Test
func testExplicitToolInvocationParsesOmniFocusDueTodayNaturalVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "What OmniFocus tasks do I have due today?",
        availableToolNames: ["focusrelay_cli"]
    )
    #expect(invocation?.toolName == "focusrelay_cli")
    #expect(invocation?.arguments["subcommand"]?.stringValue == "list-tasks")
    let args = invocation?.arguments["args"]?.arrayValue ?? []
    let renderedArgs = args.compactMap(\.stringValue).joined(separator: " ")
    #expect(renderedArgs.contains("--due-after"))
    #expect(renderedArgs.contains("--due-before"))
}

@Test
func testExplicitToolInvocationParsesTodoReadVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Show my TODO list",
        availableToolNames: ["todo_read"]
    )
    #expect(invocation?.toolName == "todo_read")
}

@Test
func testExplicitToolInvocationParsesTaskHistoryVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please show task history",
        availableToolNames: ["get_task_history"]
    )
    #expect(invocation?.toolName == "get_task_history")
}

@Test
func testExplicitToolInvocationParsesExportChatVerb() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Export chat history",
        availableToolNames: ["export_chat"]
    )
    #expect(invocation?.toolName == "export_chat")
}

@Test
func testExplicitToolInvocationParsesWriteMemoryCommandWithArguments() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: #"Please use write_memory with scope chat mode append and content "restart smoke test""#,
        availableToolNames: ["write_memory", "read_memory"]
    )
    #expect(invocation?.toolName == "write_memory")
    #expect(invocation?.arguments["scope"]?.stringValue == "chat")
    #expect(invocation?.arguments["mode"]?.stringValue == "append")
    #expect(invocation?.arguments["content"]?.stringValue == "restart smoke test")
}

@Test
func testExplicitToolInvocationParsesReadMemoryCommandWithScope() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please use read_memory with scope global",
        availableToolNames: ["write_memory", "read_memory"]
    )
    #expect(invocation?.toolName == "read_memory")
    #expect(invocation?.arguments["scope"]?.stringValue == "global")
}

@Test
func testExplicitToolInvocationParsesSubAgentWithPrompt() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: #"Please use sub_agent tool with prompt "Summarize Swift actors" and context "Concurrency migration notes" and temperature 0.2"#,
        availableToolNames: ["sub_agent"]
    )
    #expect(invocation?.toolName == "sub_agent")
    #expect(invocation?.arguments["prompt"]?.stringValue == "Summarize Swift actors")
    #expect(invocation?.arguments["context"]?.stringValue == "Concurrency migration notes")
    #expect(invocation?.arguments["temperature"]?.stringValue == "0.2")
}

@Test
func testExplicitToolInvocationParsesSendMessageWithAttachment() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: #"Please use send_message tool with message "hello from smoke" and attachment_path "/workspace/group/docs/smoke.txt" and caption "attachment test""#,
        availableToolNames: ["send_message"]
    )
    #expect(invocation?.toolName == "send_message")
    #expect(invocation?.arguments["message"]?.stringValue == "hello from smoke")
    #expect(invocation?.arguments["attachment_path"]?.stringValue == "/workspace/group/docs/smoke.txt")
    #expect(invocation?.arguments["caption"]?.stringValue == "attachment test")
}

@Test
func testExplicitToolInvocationSkipsSendMessageWithoutPayload() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please use send_message tool",
        availableToolNames: ["send_message"]
    )
    #expect(invocation == nil)
}

@Test
func testExplicitToolInvocationSkipsSubAgentWithoutPrompt() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please use sub_agent tool",
        availableToolNames: ["sub_agent"]
    )
    #expect(invocation == nil)
}

@Test
func testExplicitToolInvocationParsesCancelTaskWithId() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please cancel task task-123",
        availableToolNames: ["cancel_task"]
    )
    #expect(invocation?.toolName == "cancel_task")
    #expect(invocation?.arguments["task_id"]?.stringValue == "task-123")
}

@Test
func testExplicitToolInvocationParsesCancelTaskWithColonSyntax() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please cancel task: task-123",
        availableToolNames: ["cancel_task"]
    )
    #expect(invocation?.toolName == "cancel_task")
    #expect(invocation?.arguments["task_id"]?.stringValue == "task-123")
}

@Test
func testExplicitToolInvocationParsesCancelTaskByName() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please cancel task morning report",
        availableToolNames: ["cancel_task"]
    )
    #expect(invocation?.toolName == "cancel_task")
    #expect(invocation?.arguments["task_id"]?.stringValue == "morning report")
}

@Test
func testExplicitToolInvocationPreservesTaskIDCase() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "Please cancel task task-1770862295933-9FCA0C",
        availableToolNames: ["cancel_task"]
    )
    #expect(invocation?.toolName == "cancel_task")
    #expect(invocation?.arguments["task_id"]?.stringValue == "task-1770862295933-9FCA0C")
}

@Test
func testExplicitToolInvocationIgnoresNonExplicitMultiIntentPrompt() {
    let invocation = NanoClawAgent.explicitToolInvocation(
        for: "add and read todo",
        availableToolNames: ["todo_read", "todo_write"]
    )
    #expect(invocation == nil)
}

@Test
func testMissedMorningReportPromptDetection() {
    #expect(NanoClawAgent.isMissedMorningReportPrompt("I didn't get my morning report can you send it?"))
    #expect(NanoClawAgent.isMissedMorningReportPrompt("I didn’t get my morning Apple News product report can you send it?"))
    #expect(!NanoClawAgent.isMissedMorningReportPrompt("Please list my tasks"))
}

@Test
func testSummarizeMorningReportTaskStateActive() {
    let listOutput = "- [active] task-abc: Morning report: Apple news summary... (cron: 0 8 * * *, next: 2026-02-17T00:00:00Z)"
    let summary = NanoClawAgent.summarizeMorningReportTaskState(from: listOutput)
    #expect(summary.contains("Your morning report task is active"))
    #expect(summary.contains("task-abc"))
}
