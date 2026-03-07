import Testing

@testable import NanoClawAgent

@Test
func testExecutionRouteDefaultsToPlanAndExecuteForSimplePrompt() {
    let route = NanoClawAgent.executionRoute(for: "What is 2 + 2?")
    #expect(route == .planAndExecute)
}

@Test
func testExecutionRouteDefaultsToPlanAndExecuteForMultiStepPrompt() {
    let route = NanoClawAgent.executionRoute(
        for: "First gather recent updates, then compare alternatives, and finally produce a rollout plan."
    )
    #expect(route == .planAndExecute)
}

@Test
func testExecutionRouteDefaultsToPlanAndExecuteForNaturalLanguageTaskPrompt() {
    let route = NanoClawAgent.executionRoute(for: "Please list tasks")
    #expect(route == .planAndExecute)
}

@Test
func testExecutionRoutePrefersToolCallingForOmniFocusInboxPrompt() {
    let route = NanoClawAgent.executionRoute(
        for: "Can you use the mcp server of omnifocus and show me what is in the inbox?"
    )
    #expect(route == .toolCalling)
}

@Test
func testExecutionRoutePrefersToolCallingForFocusRelayTaskPrompt() {
    let route = NanoClawAgent.executionRoute(
        for: "Use FocusRelay MCP and list all my OmniFocus tasks."
    )
    #expect(route == .toolCalling)
}

@Test
func testExecutionRouteForcesToolCallingForScheduledAppleNewsDigest() {
    let route = NanoClawAgent.executionRoute(
        for: "Daily Apple news digest with latest product announcements.",
        isScheduledTask: true
    )
    #expect(route == .toolCalling)
}

@Test
func testExecutionRouteKeepsNonScheduledAppleNewsDigestOnDefaultRoute() {
    let route = NanoClawAgent.executionRoute(
        for: "Daily Apple news digest with latest product announcements.",
        isScheduledTask: false
    )
    #expect(route == .planAndExecute)
}

@Test
func testLoopBudgetIncreasesToolCallLimitForScheduledPlanAndExecute() {
    let unscheduled = NanoClawAgent.loopBudgetPolicy(
        for: .planAndExecute,
        timeoutSeconds: 180,
        isScheduledTask: false
    )
    let scheduled = NanoClawAgent.loopBudgetPolicy(
        for: .planAndExecute,
        timeoutSeconds: 180,
        isScheduledTask: true
    )

    #expect(scheduled.maxToolCalls >= unscheduled.maxToolCalls)
    #expect(scheduled.maxIterations == unscheduled.maxIterations)
    #expect(scheduled.timeout == unscheduled.timeout)
}

@Test
func testRetryPolicyDiffersByExecutionRoute() {
    let toolPolicy = NanoClawAgent.retryPolicy(for: .toolCalling)
    let planPolicy = NanoClawAgent.retryPolicy(for: .planAndExecute)

    #expect(toolPolicy.maxAttempts < planPolicy.maxAttempts)
    #expect(toolPolicy.initialBackoffMs < planPolicy.initialBackoffMs)
}
