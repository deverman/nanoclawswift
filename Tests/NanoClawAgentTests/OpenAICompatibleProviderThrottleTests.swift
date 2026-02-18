import Foundation
import Testing

@testable import NanoClawAgent

@Test
func testThrottleDelayIsZeroWhenUnderLimit() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = [
        now.addingTimeInterval(-50),
        now.addingTimeInterval(-30)
    ]
    let delay = OpenAICompatibleProvider.throttleDelaySeconds(
        now: now,
        recentRequests: recent,
        limitPerMinute: 3
    )
    #expect(delay == 0)
}

@Test
func testThrottleDelayComputedWhenAtLimitWithinWindow() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = [
        now.addingTimeInterval(-59),
        now.addingTimeInterval(-20),
        now.addingTimeInterval(-5)
    ]
    let delay = OpenAICompatibleProvider.throttleDelaySeconds(
        now: now,
        recentRequests: recent,
        limitPerMinute: 3
    )
    #expect(delay >= 1.0)
    #expect(delay <= 1.1)
}

@Test
func testThrottleIgnoresRequestsOutsideWindow() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = [
        now.addingTimeInterval(-120),
        now.addingTimeInterval(-70),
        now.addingTimeInterval(-10)
    ]
    let delay = OpenAICompatibleProvider.throttleDelaySeconds(
        now: now,
        recentRequests: recent,
        limitPerMinute: 2
    )
    #expect(delay == 0)
}

@Test
func testSpacingDelayRequiresGapBetweenRequests() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = [now.addingTimeInterval(-1)]
    let delay = OpenAICompatibleProvider.spacingDelaySeconds(
        now: now,
        recentRequests: recent,
        limitPerMinute: 20
    )
    #expect(delay >= 1.9)
    #expect(delay <= 2.1)
}

@Test
func testSpacingDelayIsZeroAfterRequiredGap() {
    let now = Date(timeIntervalSince1970: 1_000)
    let recent = [now.addingTimeInterval(-5)]
    let delay = OpenAICompatibleProvider.spacingDelaySeconds(
        now: now,
        recentRequests: recent,
        limitPerMinute: 20
    )
    #expect(delay == 0)
}
