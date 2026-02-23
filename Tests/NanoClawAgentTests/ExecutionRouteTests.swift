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
