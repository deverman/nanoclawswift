import Testing

@testable import NanoClawHost

@Test
func testWorkingAckMessageInitialUsesProcessingText() {
    let text = NanoClawHostService.workingAckMessage(
        assistantName: "Andy",
        repeatUpdate: false
    )

    #expect(text == "Andy: Working on it, still processing your request...")
}

@Test
func testWorkingAckMessageRepeatUsesStillWorkingText() {
    let text = NanoClawHostService.workingAckMessage(
        assistantName: "Andy",
        repeatUpdate: true
    )

    #expect(text == "Andy: Still working on your request, thanks for your patience...")
}
