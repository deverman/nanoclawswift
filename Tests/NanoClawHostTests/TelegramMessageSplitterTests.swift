import Testing

@testable import NanoClawHost

private func backtickFenceCount(in text: String) -> Int {
    var count = 0
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let range = text.range(of: "```", range: searchStart..<text.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

@Test
func testTelegramMessageSplitterReturnsSingleChunkForShortText() {
    let chunks = TelegramMessageSplitter.split("short text", limit: 20)
    #expect(chunks == ["short text"])
}

@Test
func testTelegramMessageSplitterSplitsLongTextWithinLimit() {
    let input = String(repeating: "A", count: 105)
    let chunks = TelegramMessageSplitter.split(input, limit: 40)

    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.count <= 40 })
    #expect(chunks.joined() == input)
}

@Test
func testTelegramMessageSplitterPreservesUnicodeGraphemeBoundaries() {
    let input = String(repeating: "👨‍👩‍👧‍👦", count: 40)
    let chunks = TelegramMessageSplitter.split(input, limit: 15)

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 15 })
    #expect(chunks.joined() == input)
}

@Test
func testTelegramMessageSplitterKeepsCodeFenceBalancedPerChunk() {
    let input =
        String(repeating: "intro ", count: 10) +
        "\n```swift\nprint(\\\"hello\\\")\nprint(\\\"world\\\")\n```\n" +
        String(repeating: "tail ", count: 10)

    let chunks = TelegramMessageSplitter.split(input, limit: 60)

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 60 })
    #expect(chunks.joined() == input)
    #expect(chunks.allSatisfy { backtickFenceCount(in: $0).isMultiple(of: 2) })
}

@Test
func testSplitOutboundTextOnlySplitsTelegramChannel() {
    let input = String(repeating: "x", count: 120)

    let telegram = splitOutboundText(input, for: "telegram", limit: 50)
    let other = splitOutboundText(input, for: "internal", limit: 50)

    #expect(telegram.count > 1)
    #expect(telegram.allSatisfy { $0.count <= 50 })
    #expect(telegram.joined() == input)

    #expect(other == [input])
}

@Test
func testSplitAssistantOutboundTextSplitsTelegramResponsesAfterPrefixing() {
    let modelOutput = String(repeating: "A", count: 120)
    let chunks = splitAssistantOutboundText(
        modelOutput,
        assistantName: "Andy",
        for: "telegram",
        limit: 50
    )

    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 50 })
    #expect(chunks.joined() == "Andy: \(modelOutput)")
}
