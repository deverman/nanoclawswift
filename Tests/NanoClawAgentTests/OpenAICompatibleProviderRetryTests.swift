import Foundation
import Testing

@testable import NanoClawAgent

@Test
func testParseRetryAfterSecondsFromProviderMessage() {
    let reason = #"HTTP 429: {"error":{"message":"Organization Rate limit exceeded, please try again after 1.5 seconds","type":"rate_limit_reached_error"}}"#
    let parsed = OpenAICompatibleProvider.parseRetryAfterSeconds(from: reason)
    #expect(parsed == 1.5)
}

@Test
func testParseRetryAfterSecondsReturnsNilWhenMissing() {
    let reason = "HTTP 429: overloaded without retry hint"
    let parsed = OpenAICompatibleProvider.parseRetryAfterSeconds(from: reason)
    #expect(parsed == nil)
}

@Test
func testFallbackEligibilityIncludesHTTP502Timeouts() {
    let reason = #"HTTP 502: {"error":"Upstream request failed: The request timed out."}"#
    #expect(OpenAICompatibleProvider.shouldUseFallback(forGenerationFailureReason: reason))
}

@Test
func testFallbackEligibilityIncludesTransientURLErrors() {
    #expect(OpenAICompatibleProvider.shouldUseFallback(for: URLError(.timedOut)))
    #expect(OpenAICompatibleProvider.shouldUseFallback(for: URLError(.networkConnectionLost)))
}

@Test
func testFallbackEligibilityExcludesPermanentClientErrors() {
    let reason = #"HTTP 400: {"error":"Bad request"}"#
    #expect(!OpenAICompatibleProvider.shouldUseFallback(forGenerationFailureReason: reason))
}

@Test
func testRateLimitRetryPolicyUsesLowerAttemptsAndLongerBaseDelay() {
    let policy = OpenAICompatibleProvider.rateLimitRetryPolicy()
    #expect(policy.maxRetries == 2)
    #expect(policy.baseDelaySeconds == 2.0)
}

@Test
func testCircuitBreakerPolicyOpensAfterTwo429sWithCooldown() {
    let policy = OpenAICompatibleProvider.circuitBreakerPolicy()
    #expect(policy.openAfterConsecutive429 == 2)
    #expect(policy.cooldownSeconds == 30)
}

@Test
func testRemainingCooldownSecondsUsesOpenUntil() {
    let now = Date(timeIntervalSince1970: 100)
    let openUntil = Date(timeIntervalSince1970: 125.4)
    let remaining = OpenAICompatibleProvider.remainingCooldownSeconds(now: now, openUntil: openUntil)
    #expect(abs(remaining - 25.4) < 0.001)
}

@Test
func testCapabilityLimitationDisclaimerDetectionMatchesKnownPhrases() {
    let text = "I don't have access to real-time web search results in this environment."
    #expect(OpenAICompatibleProvider.containsCapabilityLimitationDisclaimer(text))
}

@Test
func testCapabilityLimitationDisclaimerDetectionIgnoresNormalResponses() {
    let text = "Here is a summary based on the tool results."
    #expect(!OpenAICompatibleProvider.containsCapabilityLimitationDisclaimer(text))
}

@Test
func testProviderRequestDiagnosticsReportsFallbackUsageMetadata() async {
    let diagnostics = ProviderRequestDiagnostics()
    await diagnostics.recordFallback(reason: "behavioral_tool_failure")
    await diagnostics.recordFallback(reason: "tool_call_error")

    let metadata = await diagnostics.metadata()
    #expect(metadata["nanoclaw.provider_fallback_used"] == .bool(true))
    #expect(metadata["nanoclaw.provider_fallback_count"] == .int(2))
    #expect(metadata["nanoclaw.provider_fallback_reason"] == .string("tool_call_error"))
}
