import Foundation
import SwiftAgents
import Testing

@testable import NanoClawAgent

@Test
func testRetryDecisionRetriesTransientURLError() {
    let policy = ExecutionRetryPolicy(
        maxAttempts: 3,
        initialBackoffMs: 100,
        maxBackoffMs: 400
    )
    let decision = NanoClawAgent.retryDecision(
        for: URLError(.timedOut),
        attempt: 1,
        policy: policy
    )
    #expect(decision == .retry(after: Duration.milliseconds(100)))
}

@Test
func testRetryDecisionFailsOnFinalAttempt() {
    let policy = ExecutionRetryPolicy(
        maxAttempts: 2,
        initialBackoffMs: 100,
        maxBackoffMs: 200
    )
    let decision = NanoClawAgent.retryDecision(
        for: URLError(.timedOut),
        attempt: 2,
        policy: policy
    )
    #expect(decision == .fail)
}

@Test
func testRetryDecisionFailsOnNonTransientAgentError() {
    let policy = ExecutionRetryPolicy(
        maxAttempts: 3,
        initialBackoffMs: 100,
        maxBackoffMs: 400
    )
    let decision = NanoClawAgent.retryDecision(
        for: AgentError.invalidInput(reason: "missing prompt"),
        attempt: 1,
        policy: policy
    )
    #expect(decision == .fail)
}
