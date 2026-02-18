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
func scheduledRunFailureClassifierMapsProviderTimeout() {
    let cause = ScheduledRunFailureClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 502: {"error":"Upstream request failed: The request timed out."}"#
    )
    #expect(cause == .providerTimeout)
    #expect(ScheduledRunFailureClassifier.isTransient(cause) == true)
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
