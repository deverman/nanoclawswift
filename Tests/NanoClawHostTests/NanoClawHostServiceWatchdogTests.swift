import Testing

@testable import NanoClawHost

@Test
func testEffectiveWatchdogUsesRequestedWhenWithinContainerBudget() {
    let effective = NanoClawHostService.effectiveWatchdogMs(
        requestedWatchdogMs: 30_000,
        containerTimeoutMs: 120_000
    )
    #expect(effective == 30_000)
}

@Test
func testEffectiveWatchdogClampsToContainerBudgetMinusSafetyWindow() {
    let effective = NanoClawHostService.effectiveWatchdogMs(
        requestedWatchdogMs: 300_000,
        containerTimeoutMs: 120_000
    )
    #expect(effective == 119_000)
}

@Test
func testEffectiveWatchdogAppliesMinimumFloor() {
    let effective = NanoClawHostService.effectiveWatchdogMs(
        requestedWatchdogMs: 50,
        containerTimeoutMs: 200
    )
    #expect(effective == 1_000)
}
