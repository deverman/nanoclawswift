import Testing
@testable import NanoClawAgent

@Test
func recoverPseudoToolCallsParsesInvokeTranscript() {
    let output = """
    I'll fetch this now.
    <function_calls>
    <invoke name="web_search">
    <parameter name="query">Apple news product announcements February 2026 latest</parameter>
    </invoke>
    </function_calls>
    """

    let calls = OpenAICompatibleProvider.recoverPseudoToolCalls(from: output)
    #expect(calls.count == 1)
    #expect(calls[0].name == "web_search")
    #expect(calls[0].arguments["query"] == .string("Apple news product announcements February 2026 latest"))
}

@Test
func recoverPseudoToolCallsParsesToolFenceAndNormalizesAlias() {
    let output = """
    ```tool
    search_web
    {"query":"latest Apple news"}
    ```
    """

    let calls = OpenAICompatibleProvider.recoverPseudoToolCalls(from: output)
    #expect(calls.count == 1)
    #expect(calls[0].name == "web_search")
    #expect(calls[0].arguments["query"] == .string("latest Apple news"))
}

@Test
func recoverPseudoToolCallsParsesFunctionsFenceAndNormalizesBrokerAlias() {
    let output = """
    ```functions.mcp_host_broker__web_search:1
    {"query":"Swift 6 tips"}
    ```
    """

    let calls = OpenAICompatibleProvider.recoverPseudoToolCalls(from: output)
    #expect(calls.count == 1)
    #expect(calls[0].name == "web_search")
    #expect(calls[0].arguments["query"] == .string("Swift 6 tips"))
}

@Test
func containsPseudoToolSyntaxDetectsFunctionCallTranscript() {
    let output = """
    <function_calls>
    <invoke name="web_search">
    <parameter name="query">Apple</parameter>
    </invoke>
    </function_calls>
    """

    #expect(OpenAICompatibleProvider.containsPseudoToolSyntax(output))
}

@Test
func containsPseudoToolSyntaxDetectsFunctionsFenceTranscript() {
    let output = """
    ```functions.send_message:3
    {"message":"hello"}
    ```
    """

    #expect(OpenAICompatibleProvider.containsPseudoToolSyntax(output))
}
