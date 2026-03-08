import Testing

@testable import NanoClawHostCtl

@Test
func testSchedulerDiagnosticsClassifierMapsProviderRateLimit() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 429: {"error":{"message":"Organization Rate limit exceeded","type":"rate_limit_reached_error"}}"#
    )
    #expect(cause == .providerRateLimit)
}

@Test
func testSchedulerDiagnosticsClassifierMapsProviderTimeout() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 502: {"error":"Upstream request failed: The request timed out."}"#
    )
    #expect(cause == .providerTimeout)
}

@Test
func testSchedulerDiagnosticsClassifierMapsNetworkOffline() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 502: {"error":"Upstream request failed: The Internet connection appears to be offline."}"#
    )
    #expect(cause == .networkOffline)
}

@Test
func testSchedulerDiagnosticsClassifierMapsTokenOverflow() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: #"Generation failed: HTTP 400: {"error":{"message":"Invalid request: Your request exceeded model token limit: 262144","type":"invalid_request_error"}}"#
    )
    #expect(cause == .tokenOverflow)
}

@Test
func testSchedulerDiagnosticsClassifierMapsPseudoToolTranscriptToMissingToolCalls() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: "Model returned pseudo tool syntax without structured tool calls."
    )
    #expect(cause == .missingToolCalls)
}

@Test
func testSchedulerDiagnosticsClassifierMapsFreshnessGateFailuresToStaleContent() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "error",
        detail: "Scheduled news freshness check failed: missing dated sources in the report output."
    )
    #expect(cause == .staleContent)
}

@Test
func testSchedulerDiagnosticsClassifierReturnsNilForNonErrorStatus() {
    let cause = SchedulerDiagnosticsClassifier.classify(
        status: "success",
        detail: "Done"
    )
    #expect(cause == nil)
}

@Test
func testSchedulerDiagnosticsLogParserExtractsFallbackObservation() {
    let line = "2026-03-08T08:34:39+0800 info nanoclaw.host: [NanoClawHost] Completed scheduled queue job request=sched-task-1771244294918-8232D9-1772929997 group=telegram-direct status=error cause=provider_timeout transient=true providerFallbackUsed=true providerFallbackReason=primary_exhausted"
    let observation = SchedulerDiagnosticsLogParser.fallbackObservation(from: line)
    #expect(observation == SchedulerFallbackObservation(
        taskID: "task-1771244294918-8232D9",
        used: true,
        reason: "primary_exhausted"
    ))
}
