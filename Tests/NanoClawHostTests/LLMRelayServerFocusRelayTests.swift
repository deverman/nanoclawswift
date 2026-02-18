import Testing

@testable import NanoClawHost

@Test
func testHostCLICommandAndArgumentValidation() {
    #expect(LLMRelayServer.validateHostCLICommand("/opt/homebrew/bin/focusrelay"))
    #expect(LLMRelayServer.validateHostCLICommand("focusrelay"))
    #expect(!LLMRelayServer.validateHostCLICommand(""))
    #expect(!LLMRelayServer.validateHostCLICommand("focusrelay\nrm -rf /"))

    #expect(LLMRelayServer.validateHostCLIArguments(["--limit", "20"]))
    #expect(!LLMRelayServer.validateHostCLIArguments(["line1\nline2"]))
    #expect(!LLMRelayServer.validateHostCLIArguments(["abc\0def"]))
    #expect(!LLMRelayServer.validateHostCLIArguments([String(repeating: "x", count: 257)]))
}

@Test
func testHostServerIDValidation() {
    #expect(LLMRelayServer.validateMCPServerID("focusrelay"))
    #expect(LLMRelayServer.validateMCPServerID("local_server-01"))
    #expect(!LLMRelayServer.validateMCPServerID(""))
    #expect(!LLMRelayServer.validateMCPServerID("../etc/passwd"))
    #expect(!LLMRelayServer.validateMCPServerID("bad id"))
}
