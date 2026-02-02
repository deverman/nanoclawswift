import Testing
import ArgumentParser
@testable import NanoClawAgent

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
