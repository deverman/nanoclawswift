import Testing

@testable import NanoClawCommandKit

@Test
func testNotCommandWhenNoLeadingSlash() {
    #expect(SlashCommandParser.parse("Please list tasks") == .notCommand)
}

@Test
func testParsesScheduleWithQuotedPrompt() {
    let result = SlashCommandParser.parse(#"/schedule 08:30 "Review inbox and triage""#)
    #expect(result == .command(.schedule(time: "08:30", prompt: "Review inbox and triage")))
}

@Test
func testParsesMCPCliWithQuotedArg() {
    let result = SlashCommandParser.parse(#"/mcp-cli focusrelay list-tasks --search "apple news""#)
    #expect(result == .command(.mcpCLI(serverID: "focusrelay", args: ["list-tasks", "--search", "apple news"])))
}

@Test
func testInvalidScheduleUsageWithoutPrompt() {
    let result = SlashCommandParser.parse("/schedule 08:30")
    guard case .invalid(let usageError) = result else {
        Issue.record("Expected invalid parse result")
        return
    }
    #expect(usageError.command == "/schedule")
    #expect(usageError.usage == "/schedule <HH:MM> <prompt...>")
}

@Test
func testUnknownCommandReturnsUnknown() {
    let result = SlashCommandParser.parse("/does-not-exist")
    #expect(result == .unknown(name: "/does-not-exist"))
}

@Test
func testCommandsAliasParsesAsHelp() {
    let result = SlashCommandParser.parse("/commands")
    #expect(result == .command(.help))
}

@Test
func testParsesMoreWithLimit() {
    let result = SlashCommandParser.parse("/more 5")
    #expect(result == .command(.more(limit: 5)))
}

@Test
func testInvalidMoreLimitOutOfRange() {
    let result = SlashCommandParser.parse("/more 0")
    guard case .invalid(let usageError) = result else {
        Issue.record("Expected invalid parse result for /more out of range")
        return
    }
    #expect(usageError.command == "/more")
}

@Test
func testInvalidForUnterminatedQuote() {
    let result = SlashCommandParser.parse(#"/mcp-cli focusrelay --search "apple"#)
    guard case .invalid(let usageError) = result else {
        Issue.record("Expected invalid parse result for unterminated quote")
        return
    }
    #expect(usageError.command == "/mcp-cli")
}
