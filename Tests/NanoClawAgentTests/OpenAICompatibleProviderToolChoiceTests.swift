import Foundation
import Testing
import SwiftAgents

@testable import NanoClawAgent

@Test
func testForcedToolChoiceFromEnvironmentWins() {
    let tools = [
        ToolDefinition(name: "list_skills", description: "", parameters: []),
        ToolDefinition(name: "sync_skills", description: "", parameters: [])
    ]
    let messages = [["role": "user", "content": "Please use the sync_skills tool"]]

    let forced = OpenAICompatibleProvider.forcedToolChoice(
        fromMessages: messages,
        tools: tools,
        environment: ["NANOCLAW_TOOL_CHOICE": "list_skills"]
    )

    #expect(forced == "list_skills")
}

@Test
func testForcedToolChoiceInfersQuotedToolName() {
    let tools = [
        ToolDefinition(name: "list_skills", description: "", parameters: []),
        ToolDefinition(name: "sync_skills", description: "", parameters: [])
    ]
    let messages = [["role": "user", "content": "Please use the `list_skills` tool"]]

    let forced = OpenAICompatibleProvider.forcedToolChoice(
        fromMessages: messages,
        tools: tools,
        environment: [:]
    )

    #expect(forced == "list_skills")
}

@Test
func testForcedToolChoiceInfersUnquotedToolName() {
    let tools = [
        ToolDefinition(name: "activate_skill", description: "", parameters: []),
        ToolDefinition(name: "list_skills", description: "", parameters: [])
    ]
    let messages = [["role": "user", "content": "Please use the list_skills tool now."]]

    let forced = OpenAICompatibleProvider.forcedToolChoice(
        fromMessages: messages,
        tools: tools,
        environment: [:]
    )

    #expect(forced == "list_skills")
}

@Test
func testForcedToolChoiceReturnsNilForUnknownTool() {
    let tools = [
        ToolDefinition(name: "list_skills", description: "", parameters: [])
    ]
    let messages = [["role": "user", "content": "Please use the imaginary_tool tool"]]

    let forced = OpenAICompatibleProvider.forcedToolChoice(
        fromMessages: messages,
        tools: tools,
        environment: [:]
    )

    #expect(forced == nil)
}

@Test
func testSupportsForcedToolChoiceDisabledForKimiMoonshot() {
    #expect(
        OpenAICompatibleProvider.supportsForcedToolChoice(
            model: "kimi-k2.5",
            host: "api.moonshot.ai"
        ) == false
    )
}

@Test
func testSupportsForcedToolChoiceEnabledForOpenAI() {
    #expect(
        OpenAICompatibleProvider.supportsForcedToolChoice(
            model: "gpt-5.2",
            host: "api.openai.com"
        ) == true
    )
}
