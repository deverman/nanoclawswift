import Testing
import ArgumentParser
import Foundation
@testable import NanoClawAgent

private func makeDaemonRequest(
    requestID: String = UUID().uuidString,
    prompt: String = "hello",
    sessionID: String? = nil,
    chatJID: String = "telegram_1",
    groupFolder: String = "group-a",
    isMain: Bool = false,
    isScheduledTask: Bool? = false
) -> DaemonRequest {
    DaemonRequest(
        request_id: requestID,
        prompt: prompt,
        session_id: sessionID,
        chat_jid: chatJID,
        group_folder: groupFolder,
        is_main: isMain,
        is_scheduled_task: isScheduledTask
    )
}

@Test
func testCLIParsing() throws {
    let command = try NanoClawAgentCLI.parse([
        "--group-folder", "/tmp/test",
        "--chat-jid", "test@g.us"
    ])

    #expect(command.groupFolder == "/tmp/test")
    #expect(command.chatJid == "test@g.us")
    #expect(command.config == "/workspace/config.json")
}

@Test
func testDaemonAgentCacheReusesAgentForSameRequestKey() async {
    let cache = DaemonAgentCache(
        config: NanoClawConfig(apiKey: "test-key"),
        agentFactory: { request, _ in
            await NanoClawAgent(
                groupFolder: request.group_folder,
                instructions: "cache-test",
                tools: [],
                memory: nil,
                inferenceProvider: nil,
                configurationName: "CacheTest"
            )
        }
    )
    let request = makeDaemonRequest()

    _ = await cache.agent(for: request)
    _ = await cache.agent(for: request)

    #expect(await cache.buildCount() == 1)
}

@Test
func testDaemonAgentCacheRebuildsOnRequestKeyChange() async {
    let cache = DaemonAgentCache(
        config: NanoClawConfig(apiKey: "test-key"),
        agentFactory: { request, _ in
            await NanoClawAgent(
                groupFolder: request.group_folder,
                instructions: "cache-test",
                tools: [],
                memory: nil,
                inferenceProvider: nil,
                configurationName: "CacheTest"
            )
        }
    )

    _ = await cache.agent(for: makeDaemonRequest(chatJID: "telegram_1"))
    _ = await cache.agent(for: makeDaemonRequest(chatJID: "telegram_2"))

    #expect(await cache.buildCount() == 2)
}

@Test
func testShouldInvalidateDaemonAgentCacheForMCPReloadPrompts() {
    #expect(shouldInvalidateDaemonAgentCache(for: "/mcp-reload"))
    #expect(shouldInvalidateDaemonAgentCache(for: "/mcp-reload /workspace/group/.mcp.json"))
    #expect(!shouldInvalidateDaemonAgentCache(for: "/mcp-status"))
    #expect(!shouldInvalidateDaemonAgentCache(for: "Please reload mcp"))
}
