import Testing

@testable import NanoClawHost

@Test
func scheduledRunFailureClassifierMapsProviderRateLimit() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 429: {"error":{"message":"Organization Rate limit exceeded","type":"rate_limit_reached_error"}}"#
    )
    #expect(cause == .providerRateLimit)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsProviderRateLimitFromRetryAfterMessage() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Generation failed: Provider temporarily unavailable due to rate limits. Retry after 25 seconds."
    )
    #expect(cause == .providerRateLimit)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsProviderTimeout() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 502: {"error":"Upstream request failed: The request timed out."}"#
    )
    #expect(cause == .providerTimeout)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsWatchdogAndContainerTimeoutsToProviderTimeout() {
    let watchdogCause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Queue watchdog timed out after 240000ms for request sched-task-123"
    )
    #expect(watchdogCause == .providerTimeout)
    #expect(ScheduledRunFailureClassifier.isTransient(watchdogCause) == true)

    let containerCause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Timed out waiting for response (300000ms) for request sched-task-456."
    )
    #expect(containerCause == .providerTimeout)
    #expect(ScheduledRunFailureClassifier.isTransient(containerCause) == true)
}

@Test
func scheduledRunFailureClassifierMapsNetworkOffline() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 502: {"error":"Upstream request failed: Could not resolve host: api.moonshot.ai"}"#
    )
    #expect(cause == .networkOffline)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsTokenOverflow() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 400: {"error":{"message":"Invalid request: Your request exceeded model token limit: 262144","type":"invalid_request_error"}}"#
    )
    #expect(cause == .tokenOverflow)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == false)
}

@Test
func scheduledRunFailureClassifierMapsPseudoToolTranscriptToMissingToolCalls() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Model returned pseudo tool syntax without structured tool calls."
    )
    #expect(cause == .missingToolCalls)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsActualToolFailureToToolError() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "A required tool failed during execution."
    )
    #expect(cause == .toolError)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == false)
}

@Test
func scheduledRunFailureClassifierMapsMissingToolCallsAndTreatsAsTransient() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Scheduled run required tool execution, but the model returned no structured tool calls."
    )
    #expect(cause == .missingToolCalls)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierMapsFreshnessGateFailureAndTreatsAsTransient() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: "Scheduled news freshness check failed: all cited source dates are older than 7 days."
    )
    #expect(cause == .staleContent)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
}

@Test
func scheduledRunFailureClassifierReturnsNilForNonErrorStatus() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "success",
        detail: "ok"
    )
    #expect(cause == nil)
}

@Test
func scheduledFailureNoticeIncludesRateLimitHint() {
    let text = NanoClawHostService.scheduledFailureNotice(
        taskID: "task-123",
        cause: .providerRateLimit
    )
    #expect(text.contains("task-123"))
    #expect(text.lowercased().contains("rate limit"))
    #expect(!text.hasPrefix("Andy:"))
}

@Test
func scheduledFailureNoticeIncludesTokenOverflowHint() {
    let text = NanoClawHostService.scheduledFailureNotice(
        taskID: "task-999",
        cause: .tokenOverflow
    )
    #expect(text.contains("task-999"))
    #expect(text.lowercased().contains("shorten"))
}

@Test
func scheduledFailureNoticeIncludesFreshnessHint() {
    let text = NanoClawHostService.scheduledFailureNotice(
        taskID: "task-freshness",
        cause: .staleContent
    )
    #expect(text.contains("task-freshness"))
    #expect(text.lowercased().contains("fresh"))
}
