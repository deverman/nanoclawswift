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
