import Testing

@testable import NanoClawHost

@Test
func scheduledRetryPolicyAllowsTransientWithinLimit() {
    let shouldRetry = NanoClawHostService.shouldScheduleTransientRetry(
        cause: .providerTimeout,
        retryAttempt: 2,
        maxAttempts: 3
    )
    #expect(shouldRetry == true)
}

@Test
func scheduledRetryPolicyRejectsNonTransientCause() {
    let shouldRetry = NanoClawHostService.shouldScheduleTransientRetry(
        cause: .tokenOverflow,
        retryAttempt: 1,
        maxAttempts: 3
    )
    #expect(shouldRetry == false)
}

@Test
func scheduledRetryPolicyRejectsAttemptBeyondMax() {
    let shouldRetry = NanoClawHostService.shouldScheduleTransientRetry(
        cause: .providerRateLimit,
        retryAttempt: 4,
        maxAttempts: 3
    )
    #expect(shouldRetry == false)
}

@Test
func scheduledRetryBackoffUsesExponentialCap() {
    let delay1 = NanoClawHostService.retryBackoffSeconds(
        forRetryAttempt: 1,
        initialBackoffSec: 30,
        maxBackoffSec: 300
    )
    let delay2 = NanoClawHostService.retryBackoffSeconds(
        forRetryAttempt: 2,
        initialBackoffSec: 30,
        maxBackoffSec: 300
    )
    let delay4 = NanoClawHostService.retryBackoffSeconds(
        forRetryAttempt: 4,
        initialBackoffSec: 30,
        maxBackoffSec: 300
    )

    #expect(delay1 == 30)
    #expect(delay2 == 60)
    #expect(delay4 == 240)
}

@Test
func scheduledRetryBackoffClampsToMax() {
    let delay = NanoClawHostService.retryBackoffSeconds(
        forRetryAttempt: 10,
        initialBackoffSec: 30,
        maxBackoffSec: 120
    )
    #expect(delay == 120)
}

@Test
func scheduledRetryBackoffUsesFastPathForMissingToolCalls() {
    let delay = NanoClawHostService.retryBackoffSeconds(
        for: .missingToolCalls,
        retryAttempt: 1,
        initialBackoffSec: 30,
        maxBackoffSec: 300
    )
    #expect(delay == 15)
}
