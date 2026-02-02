import ArgumentParser
import Foundation

@main
struct NanoClawAgentCLI: AsyncParsableCommand {
    @Option(name: [.customShort("c"), .long], help: "Path to config JSON file")
    var config: String = "/workspace/config.json"
    
    @Option(name: [.customShort("g"), .long], help: "Group folder name")
    var groupFolder: String
    
    @Option(name: [.customShort("s"), .long], help: "Session ID for continuity")
    var sessionId: String?
    
    @Option(name: [.customShort("j"), .long], help: "Chat JID")
    var chatJid: String
    
    @Flag(name: [.customShort("m"), .long], help: "Is this the main channel")
    var isMain = false
    
    @Flag(name: [.customShort("t"), .long], help: "Is this a scheduled task")
    var isScheduledTask = false
    
    mutating func run() async throws {
        var stderr = StandardError()
        
        print("[agent-runner] Starting NanoClawSwift Agent...", to: &stderr)
        
        let config = try await ConfigLoader.load(from: config)
        print("[agent-runner] Configuration loaded for provider: \(config.provider)", to: &stderr)
        
        let prompt = try await readStdin()
        print("[agent-runner] Received prompt (\(prompt.count) chars)", to: &stderr)
        
        let agent = await NanoClawAgent(
            config: config,
            groupFolder: groupFolder,
            chatJid: chatJid,
            isMain: isMain,
            isScheduledTask: isScheduledTask
        )
        
        let result = try await agent.run(
            prompt: prompt,
            sessionId: sessionId,
            chatJid: chatJid,
            isMain: isMain,
            isScheduledTask: isScheduledTask
        )
        
        print("---NANOCLAW_OUTPUT_START---")
        print(result.json)
        print("---NANOCLAW_OUTPUT_END---")
    }
}

func readStdin() async throws -> String {
    let handle = FileHandle.standardInput
    let data = handle.readDataToEndOfFile()
    guard let string = String(data: data, encoding: .utf8) else {
        throw CLIError.invalidInput("Could not decode stdin as UTF-8")
    }
    return string
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

enum CLIError: Error {
    case invalidInput(String)
}
