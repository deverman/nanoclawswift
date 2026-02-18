import ArgumentParser
import Testing

@testable import NanoClawDevCtl

@Test
func testBuildAgentImageParsingDefaults() throws {
    let command = try NanoClawDevCtl.BuildAgentImage.parse([])
    #expect(command.mode == "slim")
    #expect(command.imageName == "nanoclawswift-agent")
}

@Test
func testBuildAgentImageParsingExplicitModeAndImageName() throws {
    let command = try NanoClawDevCtl.BuildAgentImage.parse([
        "static",
        "--image-name", "custom-agent"
    ])
    #expect(command.mode == "static")
    #expect(command.imageName == "custom-agent")
}

@Test
func testBuildAgentImageRejectsUnsupportedModeBeforeExternalWork() throws {
    var command = try NanoClawDevCtl.BuildAgentImage.parse(["bogus"])
    #expect(throws: ValidationError.self) {
        try command.run()
    }
}

@Test
func testDownloadLinuxBinaryParsingDefaults() throws {
    let command = try NanoClawDevCtl.DownloadLinuxBinary.parse([])
    #expect(command.releaseTag == "nightly")
    #expect(command.repository == "deverman/nanoclawswift")
}

@Test
func testDownloadLinuxBinaryParsingExplicitArgs() throws {
    let command = try NanoClawDevCtl.DownloadLinuxBinary.parse([
        "v1.2.3",
        "--repository", "example/repo"
    ])
    #expect(command.releaseTag == "v1.2.3")
    #expect(command.repository == "example/repo")
}

@Test
func testVerifyTelegramSoakParsingDefaults() throws {
    let command = try NanoClawDevCtl.VerifyTelegramSoak.parse([])
    #expect(command.dbPath.hasSuffix("/store/messages.db"))
    #expect(command.logFile == "/tmp/nanoclaw-host.log")
    #expect(command.chatJid == "telegram_135937217@direct")
    #expect(command.sinceMinutes == 15)
    #expect(command.minEvents == 1)
}

@Test
func testVerifyTelegramSoakParsingExplicitArgs() throws {
    let command = try NanoClawDevCtl.VerifyTelegramSoak.parse([
        "--db-path", "/tmp/messages.db",
        "--log-file", "/tmp/host.log",
        "--chat-jid", "telegram_1@direct",
        "--since-minutes", "30",
        "--min-events", "5"
    ])
    #expect(command.dbPath == "/tmp/messages.db")
    #expect(command.logFile == "/tmp/host.log")
    #expect(command.chatJid == "telegram_1@direct")
    #expect(command.sinceMinutes == 30)
    #expect(command.minEvents == 5)
}
