import Testing
@testable import NanoClawHost

@Test
func testCollapseLatestOutboundMessagesKeepsOnlyLatestPerChat() {
    let commands: [NanoClawHostService.IPCMessageCommand] = [
        .init(channel: "telegram", chatJID: "chat-a", text: "first-a", kind: "text", attachmentPath: nil, caption: nil),
        .init(channel: "telegram", chatJID: "chat-b", text: "first-b", kind: "text", attachmentPath: nil, caption: nil),
        .init(channel: "telegram", chatJID: "chat-a", text: "second-a", kind: "text", attachmentPath: nil, caption: nil)
    ]

    let collapsed = NanoClawHostService.collapseLatestOutboundMessages(commands)
    #expect(collapsed.count == 2)
    #expect(collapsed[0].chatJID == "chat-a")
    #expect(collapsed[0].text == "second-a")
    #expect(collapsed[1].chatJID == "chat-b")
    #expect(collapsed[1].text == "first-b")
}

@Test
func testResolveAttachmentHostPathMapsWorkspaceGroupPath() {
    let resolved = NanoClawHostService.resolveAttachmentHostPath(
        containerPath: "/workspace/group/reports/daily.txt",
        sourceGroupFolder: "group-a",
        groupsDir: "/tmp/groups"
    )
    #expect(resolved == "/tmp/groups/group-a/reports/daily.txt")
}

@Test
func testResolveAttachmentHostPathRejectsPathTraversal() {
    let resolved = NanoClawHostService.resolveAttachmentHostPath(
        containerPath: "/workspace/group/../../etc/passwd",
        sourceGroupFolder: "group-a",
        groupsDir: "/tmp/groups"
    )
    #expect(resolved == nil)
}

@Test
func testShouldEnqueueDirectResultWhenNoIPCOutbound() {
    #expect(
        NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "Final answer",
            ipcOutboundCount: 0
        )
    )
    #expect(
        !NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "Final answer",
            ipcOutboundCount: 2
        )
    )
    #expect(
        !NanoClawHostService.shouldEnqueueDirectResult(
            status: "success",
            result: "   ",
            ipcOutboundCount: 0
        )
    )
}

@Test
func testNormalizedScheduledTaskChatJIDUsesOwnerForTelegramDirectGroup() {
    let resolved = NanoClawHostService.normalizedScheduledTaskChatJID(
        groupFolder: "telegram-direct",
        targetChatJID: "telegram_999@direct",
        ownerDirectChatJID: "telegram_135937217@direct"
    )
    #expect(resolved == "telegram_135937217@direct")
}

@Test
func testNormalizedScheduledTaskChatJIDKeepsTargetForNonDirectGroup() {
    let resolved = NanoClawHostService.normalizedScheduledTaskChatJID(
        groupFolder: "project-ops",
        targetChatJID: "telegram_999@g.us",
        ownerDirectChatJID: "telegram_135937217@direct"
    )
    #expect(resolved == "telegram_999@g.us")
}

@Test
func testContainsPseudoToolOutputDetectsInlineToolFence() {
    let text = """
    I'll search and send a summary.```tool
    search_web
    {"query":"Apple news"}
    ```
    """
    #expect(NanoClawHostService.containsPseudoToolOutput(text))
}

@Test
func testContainsPseudoToolOutputDetectsFunctionCallTranscript() {
    let text = """
    <function_calls>
    <invoke name="mcp_focusrelay_list_tasks">
    </invoke>
    """
    #expect(NanoClawHostService.containsPseudoToolOutput(text))
}

@Test
func testContainsPseudoToolOutputDetectsFunctionCallTranscriptWithAttributes() {
    let text = """
    <function_calls count="1">
    <invoke tool="web_search" name="web_search">
    <parameter name="query">Apple news</parameter>
    </invoke>
    """
    #expect(NanoClawHostService.containsPseudoToolOutput(text))
}

@Test
func testContainsPseudoToolOutputDetectsFunctionsFenceTranscript() {
    let text = """
    ```functions.mcp_host_broker__web_search:1
    {"query":"Apple news"}
    ```
    """
    #expect(NanoClawHostService.containsPseudoToolOutput(text))
}

@Test
func testContainsPseudoToolOutputIgnoresNormalSummary() {
    #expect(!NanoClawHostService.containsPseudoToolOutput("Daily Apple report sent."))
}

@Test
func testScheduledPromptRequiresToolExecutionForReportPrompt() {
    let prompt = "Search for the latest Apple news and compile a daily digest report."
    #expect(NanoClawHostService.scheduledPromptRequiresToolExecution(prompt))
}

@Test
func testScheduledPromptRequiresToolExecutionSkipsSimpleReminder() {
    let prompt = "Send me a reminder to stretch and drink water."
    #expect(!NanoClawHostService.scheduledPromptRequiresToolExecution(prompt))
}

@Test
func testInteractivePromptRequiresToolExecutionForOmniFocusInbox() {
    let prompt = "Can you use the mcp server of omnifocus and show me what is in the inbox?"
    #expect(NanoClawHostService.interactivePromptRequiresToolExecution(prompt))
}

@Test
func testInteractivePromptRequiresToolExecutionForOmniFocusTaskList() {
    let prompt = "Can you show me all the tasks in OmniFocus that I have?"
    #expect(NanoClawHostService.interactivePromptRequiresToolExecution(prompt))
}

@Test
func testInteractivePromptRequiresToolExecutionSkipsGenericQuestion() {
    let prompt = "What can you do for me today?"
    #expect(!NanoClawHostService.interactivePromptRequiresToolExecution(prompt))
}

@Test
func testScheduledPromptRequiresFreshNewsSourcesForAppleDigest() {
    let prompt = "Send daily Apple news digest with latest updates."
    #expect(NanoClawHostService.scheduledPromptRequiresFreshNewsSources(prompt))
}

@Test
func testScheduledPromptRequiresFreshNewsSourcesSkipsNonNewsPrompt() {
    let prompt = "Daily OmniFocus priority report and inbox triage."
    #expect(!NanoClawHostService.scheduledPromptRequiresFreshNewsSources(prompt))
}

@Test
func testScheduledNewsFreshnessFailureWhenSourcesMissingDates() {
    let prompt = "Apple news digest"
    let result = """
    As of 2026-03-05

    Sources:
    - https://example.com/apple-release
    """
    let now = NanoClawHostService.parseDateReference("2026-03-05")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure != nil)
    #expect(failure?.contains("missing dated sources") == true)
}

@Test
func testScheduledNewsFreshnessFailureWhenAllDatesAreStale() {
    let prompt = "Apple news digest"
    let result = """
    Sources:
    - Example A (2026-01-20)
    - Example B (January 15, 2026)
    """
    let now = NanoClawHostService.parseDateReference("2026-03-05")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure != nil)
    #expect(failure?.contains("older than 7 days") == true)
}

@Test
func testScheduledNewsFreshnessPassesWhenRecentSourceExists() {
    let prompt = "Swift news digest"
    let result = """
    Sources:
    - Swift.org update (2026-03-03)
    - Apple Developer update (2026-03-01)
    """
    let now = NanoClawHostService.parseDateReference("2026-03-05")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure == nil)
}

@Test
func testScheduledNewsFreshnessFailsWhenMixedFreshAndStaleSourcesAppearWithoutFallbackWindow() {
    let prompt = "Swift news digest"
    let result = """
    Sources:
    - Swift.org update (2026-03-03)
    - Apple Developer update (February 20, 2026)
    """
    let now = NanoClawHostService.parseDateReference("2026-03-05")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure?.contains("older than 7 days") == true)
}

@Test
func testScheduledNewsFreshnessFailsWhenAnyDateExceedsFallbackWindow() {
    let prompt = """
    Produce a Daily Swift Tip. First, search the last 7 days. If none are available, perform a second targeted pass using the last 14 days.
    """
    let result = """
    Sources:
    - Hacking with Swift (2026-03-05)
    - SwiftLee (2026-02-17)
    """
    let now = NanoClawHostService.parseDateReference("2026-03-06")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure?.contains("older than 14 days") == true)
}

@Test
func testScheduledNewsFreshnessPassesWhenFallbackDatesStayWithinFallbackWindow() {
    let prompt = """
    Produce a Daily Swift Tip. First, search the last 7 days. If none are available, perform a second targeted pass using the last 14 days.
    """
    let result = """
    Sources:
    - Swift Weekly Brief (2026-02-24)
    """
    let now = NanoClawHostService.parseDateReference("2026-03-06")!
    let failure = NanoClawHostService.scheduledNewsFreshnessFailure(
        prompt: prompt,
        result: result,
        freshnessWindowDays: 7,
        now: now
    )
    #expect(failure == nil)
}

@Test
func testFallbackFreshnessWindowDaysUsesLargestPromptWindow() {
    let prompt = """
    First try the last 7 days. If needed, do a fallback pass using the last 14 days and never use anything older.
    """
    #expect(NanoClawHostService.fallbackFreshnessWindowDays(from: prompt) == 14)
}

@Test
func testScheduledToolRecoveryAppliesToMissingToolCalls() {
    let response = ContainerResponsePayload(
        request_id: "req-1",
        status: "error",
        result: nil,
        new_session_id: nil,
        error: "Scheduled run required tool execution, but the model returned no structured tool calls.",
        tool_calls_count: 0,
        duration_ms: 10
    )
    #expect(
        NanoClawHostService.shouldAttemptScheduledToolRecovery(
            prompt: "Daily Apple news digest",
            response: response
        )
    )
}

@Test
func testScheduledToolRecoverySkipsTimeoutFailures() {
    let response = ContainerResponsePayload(
        request_id: "req-1",
        status: "error",
        result: nil,
        new_session_id: nil,
        error: "Generation failed: HTTP 502: {\"error\":\"Upstream request failed: The request timed out.\"}",
        tool_calls_count: 0,
        duration_ms: 10
    )
    #expect(
        !NanoClawHostService.shouldAttemptScheduledToolRecovery(
            prompt: "Daily Apple news digest",
            response: response
        )
    )
}

@Test
func testScheduledToolRecoveryPromptAddsStructuredToolRequirements() {
    let prompt = NanoClawHostService.scheduledToolRecoveryPrompt(from: "Daily Apple news digest")
    #expect(prompt.contains("structured tool calls only"))
    #expect(prompt.contains("Do not describe tool calls"))
}

@Test
func testNormalizedScheduledRecoveryResponseRejectsPseudoToolOutput() {
    let response = ContainerResponsePayload(
        request_id: "req-1",
        status: "success",
        result: """
        ```tool
        search_web
        {"query":"Apple news"}
        ```
        """,
        new_session_id: nil,
        error: nil,
        tool_calls_count: 0,
        duration_ms: 10
    )
    let normalized = NanoClawHostService.normalizedScheduledRecoveryResponse(from: response)
    #expect(normalized.status == "error")
    #expect(normalized.error == "Model returned pseudo tool syntax without structured tool calls.")
}
