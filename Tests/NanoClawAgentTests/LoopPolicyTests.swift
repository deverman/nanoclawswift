import Testing
import SwiftAgents
import Foundation
@testable import NanoClawAgent

@Test
func testLoopBudgetPolicyForToolCallingRoute() {
    let budget = NanoClawAgent.loopBudgetPolicy(for: .toolCalling, timeoutSeconds: 120)
    #expect(budget.maxIterations == 16)
    #expect(budget.maxToolCalls == 16)
    #expect(budget.timeout == .seconds(120))
}

@Test
func testLoopBudgetPolicyForPlanAndExecuteRoute() {
    let budget = NanoClawAgent.loopBudgetPolicy(for: .planAndExecute, timeoutSeconds: 120)
    #expect(budget.maxIterations == 40)
    #expect(budget.maxToolCalls == 40)
    #expect(budget.timeout == .seconds(120))
}

@Test
func testLoopBudgetPolicyForScheduledToolCallingRoute() {
    let budget = NanoClawAgent.loopBudgetPolicy(
        for: .toolCalling,
        timeoutSeconds: 120,
        isScheduledTask: true
    )
    #expect(budget.maxIterations == 16)
    #expect(budget.maxToolCalls == 24)
    #expect(budget.timeout == .seconds(120))
}

@Test
func testLoopBudgetPolicyForScheduledPlanAndExecuteRoute() {
    let budget = NanoClawAgent.loopBudgetPolicy(
        for: .planAndExecute,
        timeoutSeconds: 120,
        isScheduledTask: true
    )
    #expect(budget.maxIterations == 40)
    #expect(budget.maxToolCalls == 60)
    #expect(budget.timeout == .seconds(120))
}

@Test
func testSwarmIterationCeilingExceedsPolicyBudgets() {
    let toolBudget = NanoClawAgent.loopBudgetPolicy(for: .toolCalling, timeoutSeconds: 120)
    let planBudget = NanoClawAgent.loopBudgetPolicy(for: .planAndExecute, timeoutSeconds: 120)

    #expect(NanoClawAgent.swarmIterationCeiling > toolBudget.maxIterations)
    #expect(NanoClawAgent.swarmIterationCeiling > planBudget.maxIterations)
    #expect(NanoClawAgent.swarmIterationCeiling == 60)
}

@Test
func testLoopBudgetEnforcementRejectsIterationOverflow() {
    let budget = LoopBudgetPolicy(maxIterations: 2, timeout: .seconds(60), maxToolCalls: 10)
    let result = AgentResult(output: "ok", iterationCount: 3, duration: .seconds(1))

    do {
        try NanoClawAgent.enforceLoopBudget(result, budget: budget)
        Issue.record("Expected iteration overflow to throw")
    } catch let error as AgentError {
        #expect(error == .maxIterationsExceeded(iterations: 3))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func testLoopBudgetEnforcementRejectsToolCallOverflow() {
    let budget = LoopBudgetPolicy(maxIterations: 10, timeout: .seconds(60), maxToolCalls: 1)
    let firstCall = ToolCall(toolName: "echo")
    let secondCall = ToolCall(toolName: "echo")
    let result = AgentResult(
        output: "ok",
        toolCalls: [firstCall, secondCall],
        iterationCount: 2,
        duration: .seconds(1)
    )

    do {
        try NanoClawAgent.enforceLoopBudget(result, budget: budget)
        Issue.record("Expected tool-call overflow to throw")
    } catch let error as AgentError {
        guard case .internalError(let reason) = error else {
            Issue.record("Expected internalError, got: \(error)")
            return
        }
        #expect(reason.contains("tool call budget"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test
func testRetryDecisionRetriesTransientNetworkErrors() {
    let policy = ExecutionRetryPolicy(maxAttempts: 3, initialBackoffMs: 200, maxBackoffMs: 800)
    let decision = NanoClawAgent.retryDecision(
        for: URLError(.networkConnectionLost),
        attempt: 1,
        policy: policy
    )

    switch decision {
    case .retry(let delay):
        #expect(delay == .milliseconds(200))
    case .fail:
        Issue.record("Expected retry decision")
    }
}

@Test
func testRetryDecisionRetriesRateLimitGenerationFailures() {
    let policy = ExecutionRetryPolicy(maxAttempts: 3, initialBackoffMs: 200, maxBackoffMs: 800)
    let decision = NanoClawAgent.retryDecision(
        for: AgentError.generationFailed(reason: "HTTP 429: overloaded"),
        attempt: 1,
        policy: policy
    )

    switch decision {
    case .retry(let delay):
        #expect(delay == .milliseconds(200))
    case .fail:
        Issue.record("Expected retry decision")
    }
}

@Test
func testRetryDecisionDoesNotRetryNonTransientErrors() {
    let policy = ExecutionRetryPolicy(maxAttempts: 3, initialBackoffMs: 200, maxBackoffMs: 800)
    let decision = NanoClawAgent.retryDecision(
        for: AgentError.invalidInput(reason: "missing prompt"),
        attempt: 1,
        policy: policy
    )

    #expect(decision == .fail)
}

@Test
func testRetryDecisionStopsAfterMaxAttempts() {
    let policy = ExecutionRetryPolicy(maxAttempts: 2, initialBackoffMs: 200, maxBackoffMs: 800)
    let decision = NanoClawAgent.retryDecision(
        for: URLError(.timedOut),
        attempt: 2,
        policy: policy
    )

    #expect(decision == .fail)
}
