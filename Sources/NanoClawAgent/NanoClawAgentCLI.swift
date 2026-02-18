import ArgumentParser
import Foundation
import Logging

@main
struct NanoClawAgentCLI: AsyncParsableCommand {
    @Option(name: [.customShort("c"), .long], help: "Path to config JSON file")
    var config: String = "/workspace/config.json"
    
    @Option(name: [.customShort("g"), .long], help: "Group folder name")
    var groupFolder: String
    
    @Option(name: [.customShort("s"), .long], help: "Session ID for continuity")
    var sessionId: String?
    
    @Option(name: [.customShort("j"), .long], help: "Chat JID")
    var chatJid: String?
    
    @Flag(name: [.customShort("m"), .long], help: "Is this the main channel")
    var isMain = false
    
    @Flag(name: [.customShort("t"), .long], help: "Is this a scheduled task")
    var isScheduledTask = false

    @Flag(name: [.long], help: "Run in long-lived daemon mode using IPC request/response files")
    var daemon = false

    @Option(name: [.long], help: "Daemon poll interval in milliseconds")
    var daemonPollMs: Int = 150
    
    mutating func run() async throws {
        let logger = NanoClawLog.make("nanoclaw.cli")
        var stderr = StandardError()
        
        if daemon {
            print("[agent-daemon] Starting NanoClawSwift Agent daemon...", to: &stderr)
            try await runDaemon(logger: logger, stderr: &stderr)
            return
        }

        print("[agent-runner] Starting NanoClawSwift Agent...", to: &stderr)
        do {
            try await runSingle(logger: logger, stderr: &stderr)
        } catch {
            logger.error("CLI run failed", metadata: ["error": "\(error)"])
            throw error
        }
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

// MARK: - Daemon IPC types

struct DaemonRequest: Codable, Sendable {
    let request_id: String
    let prompt: String
    let session_id: String?
    let chat_jid: String
    let group_folder: String
    let is_main: Bool
    let is_scheduled_task: Bool?
}

struct DaemonResponse: Codable, Sendable {
    let request_id: String
    let status: String
    let result: String?
    let new_session_id: String?
    let error: String?
    let tool_calls_count: Int
    let duration_ms: Int
}

struct DaemonAgentCacheKey: Equatable, Sendable {
    let groupFolder: String
    let chatJid: String
    let isMain: Bool
    let isScheduledTask: Bool

    init(request: DaemonRequest) {
        self.groupFolder = request.group_folder
        self.chatJid = request.chat_jid
        self.isMain = request.is_main
        self.isScheduledTask = request.is_scheduled_task ?? false
    }
}

typealias DaemonAgentFactory = @Sendable (_ request: DaemonRequest, _ config: NanoClawConfig) async -> NanoClawAgent

actor DaemonAgentCache {
    private let config: NanoClawConfig
    private let agentFactory: DaemonAgentFactory
    private var cachedKey: DaemonAgentCacheKey?
    private var cachedAgent: NanoClawAgent?
    private var buildCountValue = 0

    init(
        config: NanoClawConfig,
        agentFactory: @escaping DaemonAgentFactory = { request, config in
            await NanoClawAgent(
                config: config,
                groupFolder: request.group_folder,
                chatJid: request.chat_jid,
                isMain: request.is_main,
                isScheduledTask: request.is_scheduled_task ?? false
            )
        }
    ) {
        self.config = config
        self.agentFactory = agentFactory
    }

    func agent(for request: DaemonRequest) async -> NanoClawAgent {
        let key = DaemonAgentCacheKey(request: request)
        if key == cachedKey, let cachedAgent {
            return cachedAgent
        }

        let agent = await agentFactory(request, config)
        cachedKey = key
        cachedAgent = agent
        buildCountValue += 1
        return agent
    }

    func invalidate() {
        cachedKey = nil
        cachedAgent = nil
    }

    func buildCount() -> Int {
        buildCountValue
    }
}

func shouldInvalidateDaemonAgentCache(for prompt: String) -> Bool {
    let patterns = [
        #"^\s*(?:please\s+)?(?:use|run|call)\s+(?:the\s+)?mcp_reload(?:\s+tool)?\b"#,
        #"^\s*(?:please\s+)?(?:reload|refresh)\s+mcp(?:\s+tools?)?\s*[.!?]?\s*$"#,
        #"^\s*(?:please\s+)?mcp\s+reload\s*[.!?]?\s*$"#
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        if regex.firstMatch(in: prompt, options: [], range: range) != nil {
            return true
        }
    }
    return false
}

private extension NanoClawAgentCLI {
    mutating func runSingle(logger: Logger, stderr: inout StandardError) async throws {
        guard let chatJid, !chatJid.isEmpty else {
            throw CLIError.invalidInput("Missing --chat-jid (required when not using --daemon)")
        }

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

    mutating func runDaemon(logger: Logger, stderr: inout StandardError) async throws {
        let loadedConfig = try await ConfigLoader.load(from: config)
        let agentCache = DaemonAgentCache(config: loadedConfig)
        let ipcBasePath = ProcessInfo.processInfo.environment["NANOCLAW_IPC_BASE_PATH"] ?? "/workspace/ipc"
        let inputDir = URL(fileURLWithPath: ipcBasePath).appendingPathComponent("input")
        let outputDir = URL(fileURLWithPath: ipcBasePath).appendingPathComponent("output")
        let closeSentinel = URL(fileURLWithPath: ipcBasePath).appendingPathComponent("_close")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        print("[agent-daemon] Listening for requests in \(inputDir.path)", to: &stderr)

        while true {
            if fileManager.fileExists(atPath: closeSentinel.path) {
                print("[agent-daemon] Close sentinel detected, shutting down", to: &stderr)
                try? fileManager.removeItem(at: closeSentinel)
                return
            }

            let requestFiles = try fileManager
                .contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.lastPathComponent.hasPrefix("req-") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if requestFiles.isEmpty {
                try await Task.sleep(for: .milliseconds(daemonPollMs))
                continue
            }

            for requestFile in requestFiles {
                do {
                    let response = try await processDaemonRequest(
                        requestFile: requestFile,
                        cache: agentCache
                    )
                    try writeDaemonResponse(response, outputDir: outputDir)
                } catch {
                    logger.error("Daemon request failed", metadata: [
                        "file": "\(requestFile.path)",
                        "error": "\(error)"
                    ])
                    let fallback = DaemonResponse(
                        request_id: requestID(from: requestFile),
                        status: "error",
                        result: nil,
                        new_session_id: nil,
                        error: error.localizedDescription,
                        tool_calls_count: 0,
                        duration_ms: 0
                    )
                    try? writeDaemonResponse(fallback, outputDir: outputDir)
                }
                try? fileManager.removeItem(at: requestFile)
            }
        }
    }

    func processDaemonRequest(
        requestFile: URL,
        cache: DaemonAgentCache
    ) async throws -> DaemonResponse {
        let startedAt = Date()
        let data = try Data(contentsOf: requestFile)
        let request = try JSONDecoder().decode(DaemonRequest.self, from: data)

        let agent = await cache.agent(for: request)

        do {
            let result = try await agent.run(
                prompt: request.prompt,
                sessionId: request.session_id,
                chatJid: request.chat_jid,
                isMain: request.is_main,
                isScheduledTask: request.is_scheduled_task ?? false
            )
            if shouldInvalidateDaemonAgentCache(for: request.prompt) {
                await cache.invalidate()
            }
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            return DaemonResponse(
                request_id: request.request_id,
                status: "success",
                result: result.result,
                new_session_id: result.newSessionId,
                error: nil,
                tool_calls_count: result.toolCallsCount,
                duration_ms: durationMs
            )
        } catch {
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            return DaemonResponse(
                request_id: request.request_id,
                status: "error",
                result: nil,
                new_session_id: request.session_id,
                error: error.localizedDescription,
                tool_calls_count: 0,
                duration_ms: durationMs
            )
        }
    }

    func writeDaemonResponse(_ response: DaemonResponse, outputDir: URL) throws {
        let finalURL = outputDir.appendingPathComponent("res-\(response.request_id).json")
        let data = try JSONEncoder().encode(response)
        try data.write(to: finalURL, options: .atomic)
    }

    func requestID(from requestFile: URL) -> String {
        let fileName = requestFile.lastPathComponent
        let trimmedPrefix = fileName.replacingOccurrences(of: "req-", with: "")
        return trimmedPrefix.replacingOccurrences(of: ".json", with: "")
    }
}
